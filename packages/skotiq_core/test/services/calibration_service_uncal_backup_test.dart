import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }
}

class _RecordingCalBackend extends DisconnectedBackend {
  @override
  Future<void> calibrateImageFile({
    required String lightPath,
    String? darkPath,
    String? flatPath,
    String? biasPath,
    required String outputPath,
  }) async {
    await File(outputPath).writeAsString('calibrated');
  }
}

void main() {
  test(
    'a .uncal backup is written only when calibration replaces the light',
    () async {
      final dir = await Directory.systemTemp.createTemp('cal_backup_');
      addTearDown(() => dir.delete(recursive: true));
      final light = File(p.join(dir.path, 'sub_001.fits'))
        ..writeAsStringSync('raw-light');
      final dark = File(p.join(dir.path, 'master_dark.fits'))
        ..writeAsStringSync('master-dark');
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, _RecordingCalBackend()),
          ),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(calibrationServiceProvider);
      final settings = CalibrationSettings(
        autoDarkFromLibrary: false,
        manualDarkPath: dark.path,
      );

      final sibling = await service.calibrateFile(
        lightPath: light.path,
        settings: settings,
      );
      expect(sibling.outputPath, p.join(dir.path, 'sub_001_cal.fits'));
      expect(File('${light.path}.uncal').existsSync(), isFalse);

      await service.calibrateFile(
        lightPath: light.path,
        outputPath: light.path,
        settings: settings,
      );
      expect(File('${light.path}.uncal').existsSync(), isTrue);
      expect(File('${light.path}.uncal').readAsStringSync(), 'raw-light');
    },
  );
}
