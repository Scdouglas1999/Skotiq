import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// The planetarium FOV overlay is fed exclusively from the active profile's
/// [OpticalConfig] via these two converters (see `equipmentFovBindingProvider`).
/// Their contract is that an unknown input yields null — never a stand-in rig —
/// because a null slot makes `EquipmentFOVState.fov` null, which is what makes
/// the overlay painter draw nothing instead of a plausible-looking wrong box.
void main() {
  group('telescopeSpecsFromOpticalConfig', () {
    test('maps a profile with a focal length', () {
      final specs = telescopeSpecsFromOpticalConfig(
        const OpticalConfig(
          telescopeName: 'ED80',
          focalLength: 480,
          aperture: 80,
        ),
      );

      expect(specs, isNotNull);
      expect(specs!.name, 'ED80');
      expect(specs.focalLengthMm, 480);
      expect(specs.apertureMm, 80);
    });

    test('falls back to a generic name but keeps the real focal length', () {
      final specs = telescopeSpecsFromOpticalConfig(
        const OpticalConfig(focalLength: 700),
      );

      expect(specs, isNotNull);
      expect(specs!.name, 'Telescope');
      expect(specs.focalLengthMm, 700);
      expect(specs.apertureMm, 0);
    });

    test('is null without a config or a usable focal length', () {
      expect(telescopeSpecsFromOpticalConfig(null), isNull);
      expect(telescopeSpecsFromOpticalConfig(const OpticalConfig()), isNull);
      expect(
        telescopeSpecsFromOpticalConfig(const OpticalConfig(focalLength: 0)),
        isNull,
      );
      expect(
        telescopeSpecsFromOpticalConfig(const OpticalConfig(focalLength: -1)),
        isNull,
      );
    });
  });

  group('cameraSensorSpecsFromOpticalConfig', () {
    test('converts a connected camera geometry to millimetres', () {
      final specs = cameraSensorSpecsFromOpticalConfig(
        const OpticalConfig(
          cameraName: 'ASI2600MM',
          sensorWidth: 6248,
          sensorHeight: 4176,
          pixelSize: 3.76,
        ),
      );

      expect(specs, isNotNull);
      expect(specs!.name, 'ASI2600MM');
      expect(specs.pixelsX, 6248);
      expect(specs.pixelsY, 4176);
      expect(specs.pixelSizeMicrons, 3.76);
      expect(specs.widthMm, closeTo(23.49, 0.01));
      expect(specs.heightMm, closeTo(15.70, 0.01));
    });

    test('is null when any sensor dimension is unknown', () {
      expect(cameraSensorSpecsFromOpticalConfig(null), isNull);
      expect(
        cameraSensorSpecsFromOpticalConfig(
          // Profile with optics but no camera connected: no sensor is known,
          // so no sensor may be invented.
          const OpticalConfig(focalLength: 480, telescopeName: 'ED80'),
        ),
        isNull,
      );
      expect(
        cameraSensorSpecsFromOpticalConfig(
          const OpticalConfig(sensorWidth: 6248, sensorHeight: 4176),
        ),
        isNull,
      );
      expect(
        cameraSensorSpecsFromOpticalConfig(
          const OpticalConfig(sensorWidth: 6248, pixelSize: 3.76),
        ),
        isNull,
      );
      expect(
        cameraSensorSpecsFromOpticalConfig(
          const OpticalConfig(
            sensorWidth: 0,
            sensorHeight: 4176,
            pixelSize: 3.76,
          ),
        ),
        isNull,
      );
    });
  });

  test('a fully-described rig reproduces the OpticalConfig field of view', () {
    const config = OpticalConfig(
      focalLength: 480,
      sensorWidth: 6248,
      sensorHeight: 4176,
      pixelSize: 3.76,
    );

    final state = EquipmentFOVState(
      telescope: telescopeSpecsFromOpticalConfig(config),
      camera: cameraSensorSpecsFromOpticalConfig(config),
    );

    final expected = config.fieldOfView;
    expect(expected, isNotNull);
    expect(state.fov, isNotNull);
    expect(state.fov!.$1, closeTo(expected!.$1, 1e-9));
    expect(state.fov!.$2, closeTo(expected.$2, 1e-9));
  });
}
