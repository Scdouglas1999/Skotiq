// Live auto-calibration (frames calibrated as they are captured) picks the
// flat for each light's own filter from the flat library, by its exact name.
// With the fixed master flat left at the Ha flat, an OIII light is still
// divided by the OIII flat.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }
}

class _RecordingCalBackend extends DisconnectedBackend {
  final flats = <String?>[];

  @override
  Future<void> calibrateImageFile({
    required String lightPath,
    String? darkPath,
    String? flatPath,
    String? biasPath,
    required String outputPath,
  }) async {
    flats.add(flatPath);
    await File(outputPath).writeAsString('calibrated');
  }
}

void main() {
  late Directory dir;
  late SkotiqDatabase db;
  late ProviderContainer container;
  late File haFlat;
  late File bias;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('live_flat_');
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    haFlat = File(p.join(dir.path, 'MasterFlat_Ha.fits'))
      ..writeAsStringSync('ha-flat');
    bias = File(p.join(dir.path, 'MasterBias.fits'))..writeAsStringSync('b');
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, _RecordingCalBackend()),
        ),
      ],
    );
    await container
        .read(flatLibraryDaoProvider)
        .addEntry(filePath: haFlat.path, filter: 'Ha', gain: 100, offset: 50);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<CalibrationResult> calibrate(String filter, {bool library = true}) {
    final light = File(p.join(dir.path, 'M27_${filter}_001.fits'))
      ..writeAsStringSync('light');
    return container
        .read(calibrationServiceProvider)
        .calibrateFile(
          lightPath: light.path,
          // The settings as the operator left them after an Ha session.
          settings: CalibrationSettings(
            autoCalibrate: true,
            autoDarkFromLibrary: false,
            autoFlatFromLibrary: library,
            masterFlatPath: haFlat.path,
            masterBiasPath: bias.path,
          ),
          exposureTime: 300,
          gain: 100,
          offset: 50,
          filter: filter,
        );
  }

  test('an OIII light is not divided by the Ha flat', () async {
    final result = await calibrate('OIII');
    expect(result.flatUsed, isNull);
    expect(result.flatApplied, isFalse);
  });

  test('an Ha light takes the library Ha flat', () async {
    final result = await calibrate(' ha ');
    expect(result.flatUsed, haFlat.path);
  });

  test('another spelling of the band is not the same flat', () async {
    final result = await calibrate('Ha 7nm');
    expect(result.flatUsed, isNull);
  });

  test('with the library pick off, the fixed flat file is used', () async {
    final result = await calibrate('OIII', library: false);
    expect(result.flatUsed, haFlat.path);
  });
}
