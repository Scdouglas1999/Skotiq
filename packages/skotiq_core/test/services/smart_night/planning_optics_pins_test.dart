import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

import '../../fakes/fake_target_scoring.dart';

class _MockLoggingService extends Mock implements LoggingService {}

const _pinsPath = 'test/services/smart_night/planning_optics_pins.json';

/// Which optics Smart Night plans with when the profile and the exposure
/// context disagree or leave a field out: each case's planned rows (or the
/// refusal). With a context every figure is the context's; without one, the
/// profile's. An unknown pixel size refuses, naming it. Run with
/// SKOTIQ_WRITE_PINS=1 to record.
void main() {
  final service = SmartNightService(
    suggestionService: TargetSuggestionService(
      loggingService: _MockLoggingService(),
      scorer: TargetScorer(FakeTargetScoring()),
    ),
    logging: _MockLoggingService(),
    floor: const AltitudeFloor(horizon: null, minimumDeg: 0),
  );

  const knownCamera = 'ZWO ASI2600MM Pro';
  const unknownCamera = 'Nobody Cam 9000';
  final profiles = <String, EquipmentProfileModel>{
    'full': const EquipmentProfileModel(
      id: 1,
      name: 'full',
      focalLength: 350,
      aperture: 71,
      cameraName: knownCamera,
      defaultGain: 100,
    ),
    'telescopeOnly': const EquipmentProfileModel(
      id: 2,
      name: 'telescopeOnly',
      telescopeFocalLength: 480,
      telescopeAperture: 80,
      cameraName: knownCamera,
      defaultGain: 100,
    ),
    'unknownCamera': const EquipmentProfileModel(
      id: 3,
      name: 'unknownCamera',
      focalLength: 350,
      aperture: 71,
      cameraName: unknownCamera,
    ),
    'noOptics': const EquipmentProfileModel(
      id: 4,
      name: 'noOptics',
      cameraName: knownCamera,
    ),
  };
  final contexts = <String, SmartNightExposureContext?>{
    'none': null,
    'context': const SmartNightExposureContext(
      camera: CameraExposureSpec(
        readNoiseE: 1.2,
        fullWellE: 50000,
        qePeak: 0.8,
      ),
      bortleClass: 7,
      focalLengthMm: 600,
      apertureMm: 120,
      pixelSizeMicrons: 2.4,
      guideRmsArcsec: 0.9,
      guideSampleCount: 40,
    ),
    'contextUnknownPixel': const SmartNightExposureContext(
      camera: CameraExposureSpec(
        readNoiseE: 1.2,
        fullWellE: 50000,
        qePeak: 0.8,
      ),
      bortleClass: 7,
      focalLengthMm: 600,
      apertureMm: 120,
      pixelSizeMicrons: null,
    ),
    'contextNoPixel': const SmartNightExposureContext(
      camera: CameraExposureSpec(readNoiseE: 3, fullWellE: 20000, qePeak: 0.6),
      bortleClass: 3,
      focalLengthMm: 0,
      apertureMm: 0,
      pixelSizeMicrons: 0,
    ),
  };
  final sets = <String, FilterSet>{
    'L': FilterSet.single('L'),
    'Ha': FilterSet.single('Ha'),
  };

  Map<String, Object?> compute() {
    final out = <String, Object?>{};
    for (final p in profiles.entries) {
      for (final c in contexts.entries) {
        for (final s in sets.entries) {
          final key = '${p.key}/${c.key}/${s.key}';
          try {
            final rows = service.smartExposureRows(
              profile: p.value,
              filterSet: s.value,
              plannedSecs: 3 * 3600,
              exposureContext: c.value,
            );
            out[key] = [for (final r in rows) r.toJson()];
          } on SmartNightBuildException catch (e) {
            out[key] = 'refused: ${e.message}';
          }
        }
      }
    }
    return out;
  }

  test('planned rows per profile and exposure context', () {
    final actual = jsonDecode(jsonEncode(compute()));
    final file = File(_pinsPath);
    if (Platform.environment['SKOTIQ_WRITE_PINS'] == '1') {
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(actual)}\n',
      );
    }
    final expected = jsonDecode(file.readAsStringSync());
    expect(actual, expected);
  });
}
