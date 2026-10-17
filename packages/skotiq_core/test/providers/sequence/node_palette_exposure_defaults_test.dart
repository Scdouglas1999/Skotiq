import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/sequence/node_palette.dart';
import 'package:skotiq_core/src/providers/session_optimizer_provider.dart';
import 'package:skotiq_core/src/services/session_optimizer_service.dart';
import 'package:skotiq_core/src/services/smart_night/exposure_calculator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Take Exposures palette item uses Smart Night light exposure default',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(
              name: 'Test rig',
              focalLength: 384,
              aperture: 80,
              filterNames: ['L', 'Ha'],
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
              availableFilterNames: ['L', 'Ha'],
              userCapSeconds: 240,
              floorSeconds: 30,
            ),
          ),
        ],
      );
      final exposureContextSubscription = container.listen(
        smartNightExposureContextProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(() async {
        exposureContextSubscription.close();
        container.dispose();
        await Future<void>.delayed(Duration.zero);
        await db.close();
      });

      container.read(nodePaletteProvider);
      await container.read(smartNightExposureContextProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final item = container
          .read(nodePaletteProvider)
          .expand((category) => category.items)
          .singleWhere((item) => item.name == 'Take exposures');

      final node = item.createNode() as ExposureNode;

      expect(node.durationSecs, 30);
    },
  );
}
