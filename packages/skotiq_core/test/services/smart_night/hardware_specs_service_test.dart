import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/smart_night/hardware_specs_service.dart';

void main() {
  group('HardwareSpecsService', () {
    const noOverrides = HardwareSpecsService();

    const asi2600Override = CameraHardwareSpec(
      model: 'ZWO ASI2600MM Pro',
      aliases: ['ASI2600MM'],
      pixelSizeMicrons: 4.5,
      qePeak: 0.75,
      defaultGain: 10,
      sensorWidthPx: 6200,
      sensorHeightPx: 4100,
      gainPoints: [
        CameraGainPoint(gain: 0, readNoiseE: 4.4, fullWellE: 50000),
        CameraGainPoint(gain: 10, readNoiseE: 2.2, fullWellE: 30000),
      ],
    );

    test('a camera with no override resolves nothing here', () {
      expect(
        noOverrides
            .overridesFor(cameraName: 'ZWO ASI2600MM Pro', gain: 100)
            .isEmpty,
        isTrue,
      );
    });

    test('an override answers to its model and to its aliases', () {
      const service = HardwareSpecsService(cameraOverrides: [asi2600Override]);
      for (final name in [
        'ZWO ASI2600MM Pro',
        'zwo asi2600mm pro',
        'ASI2600MM',
        'asi2600mm',
      ]) {
        final overrides = service.overridesFor(cameraName: name, gain: 10);
        expect(overrides.pixelSizeMicrons, 4.5, reason: name);
        expect(overrides.readNoiseE, 2.2, reason: name);
        expect(overrides.fullWellE, 30000, reason: name);
        expect(overrides.qePeakFraction, 0.75, reason: name);
        expect(overrides.sensorWidthPx, 6200, reason: name);
        expect(overrides.sensorHeightPx, 4100, reason: name);
      }
    });

    test('a NEAR-MISS name does not pick up the override', () {
      // The old matcher matched on edit distance ≤ 3 plus a substring rule, so
      // an ASI2400MC Pro (5.94 µm) silently inherited the ASI2600's 3.76 µm
      // and an ASI183MM Pro inherited the ASI533's. Nothing but an exact
      // normalised name may match.
      const service = HardwareSpecsService(cameraOverrides: [asi2600Override]);
      for (final name in [
        'ASI2400MC Pro',
        'ASI2600MC Pro',
        'ASI2601MM',
        'ASI260MM',
        'ASI2600',
      ]) {
        expect(
          service.overridesFor(cameraName: name, gain: 10).isEmpty,
          isTrue,
          reason: name,
        );
      }
    });

    test('the device id is matched when the friendly name misses', () {
      const service = HardwareSpecsService(cameraOverrides: [asi2600Override]);
      final overrides = service.overridesFor(
        cameraName: 'Backyard rig camera',
        cameraId: 'ASI2600MM',
        gain: 10,
      );
      expect(overrides.pixelSizeMicrons, 4.5);
    });

    test('the user\'s own gain curve is interpolated between their points', () {
      const service = HardwareSpecsService(cameraOverrides: [asi2600Override]);
      final overrides = service.overridesFor(cameraName: 'ASI2600MM', gain: 5);
      expect(overrides.readNoiseE, closeTo(3.3, 1e-9));
      expect(overrides.fullWellE, closeTo(40000, 1e-9));
    });

    test('outside their points the curve clamps to the ends', () {
      const service = HardwareSpecsService(cameraOverrides: [asi2600Override]);
      expect(
        service.overridesFor(cameraName: 'ASI2600MM', gain: -50).readNoiseE,
        4.4,
      );
      expect(
        service.overridesFor(cameraName: 'ASI2600MM', gain: 500).readNoiseE,
        2.2,
      );
    });

    test('no gain given falls back to the override\'s own default', () {
      const service = HardwareSpecsService(cameraOverrides: [asi2600Override]);
      expect(service.overridesFor(cameraName: 'ASI2600MM').readNoiseE, 2.2);
    });

    test('parses camera override specs from JSON', () {
      final spec = CameraHardwareSpec.fromJson({
        'model': 'Mystery Camera 42',
        'aliases': ['MysteryCam'],
        'pixelSizeMicrons': 4.63,
        'qePeak': 0.72,
        'defaultGain': 10,
        'gainPoints': [
          {'gain': 10, 'readNoiseE': 2.1, 'fullWellE': 42000},
        ],
      });

      expect(spec.model, 'Mystery Camera 42');
      expect(spec.aliases, ['MysteryCam']);
      expect(spec.gainPoints.single.fullWellE, 42000);
      // Sensor dimensions are optional: they were added after the first
      // overrides shipped, and an old row must still load.
      expect(spec.sensorWidthPx, isNull);
      expect(spec.sensorHeightPx, isNull);
    });

    test('serializes camera override specs to JSON', () {
      final restored = CameraHardwareSpec.fromJson(asi2600Override.toJson());

      expect(restored.model, asi2600Override.model);
      expect(restored.aliases, asi2600Override.aliases);
      expect(restored.pixelSizeMicrons, asi2600Override.pixelSizeMicrons);
      expect(restored.qePeak, asi2600Override.qePeak);
      expect(restored.defaultGain, asi2600Override.defaultGain);
      expect(restored.sensorWidthPx, 6200);
      expect(restored.sensorHeightPx, 4100);
      expect(restored.gainPoints.first.readNoiseE, 4.4);
    });

    test('a spec with no gainPoints LIST at all is refused', () {
      expect(
        () => CameraHardwareSpec.fromJson({
          'model': 'Mystery Camera 42',
          'pixelSizeMicrons': 4.63,
          'defaultGain': 10,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('an override may claim geometry and no noise figures', () {
      // A user who opened the dialog to fix a pixel size must not come away
      // having also asserted a read noise, so an empty gain-point list is
      // legitimate and the noise fields stay unresolved here.
      final spec = CameraHardwareSpec.fromJson({
        'model': 'Mystery Camera 42',
        'pixelSizeMicrons': 4.63,
        'defaultGain': 10,
        'gainPoints': <Object>[],
      });
      expect(spec.pixelSizeMicrons, 4.63);
      expect(spec.qePeak, isNull);
      expect(spec.gainPointFor(10), isNull);

      final overrides = HardwareSpecsService(
        cameraOverrides: [spec],
      ).overridesFor(cameraName: 'Mystery Camera 42', gain: 10);
      expect(overrides.pixelSizeMicrons, 4.63);
      expect(overrides.readNoiseE, isNull);
      expect(overrides.fullWellE, isNull);
      expect(overrides.qePeakFraction, isNull);
    });

    test('a field the user left out is absent from the JSON', () {
      const spec = CameraHardwareSpec(
        model: 'Mystery Camera 42',
        defaultGain: 10,
        gainPoints: [
          CameraGainPoint(gain: 10, readNoiseE: 2.1, fullWellE: 42000),
        ],
      );
      final json = spec.toJson();
      expect(json.containsKey('pixelSizeMicrons'), isFalse);
      expect(json.containsKey('qePeak'), isFalse);
      expect(CameraHardwareSpec.fromJson(json).pixelSizeMicrons, isNull);
    });

    test('overrides parse from a JSON list and reject a non-list', () {
      final specs = HardwareSpecsService.cameraOverridesFromJson([
        asi2600Override.toJson(),
      ]);
      expect(specs.single.model, 'ZWO ASI2600MM Pro');
      expect(HardwareSpecsService.cameraOverridesFromJson(null), isEmpty);
      expect(
        () => HardwareSpecsService.cameraOverridesFromJson({'model': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
