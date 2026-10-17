import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_core/src/services/hardware_presets/hardware_presets_service.dart';

void main() {
  test('ASI1600 aliases select broadband and narrowband recipes', () {
    for (final name in ['ZWO ASI1600MM-Cool', 'ASI1600MM Pro', 'ASI1600MM']) {
      for (final filter in ['L', 'R', 'Green', 'Blue']) {
        expect(
          resolveCameraCaptureDefaults(cameraName: name, filterName: filter),
          (gain: 76, offset: 15),
        );
      }
      for (final filter in ['Ha', 'H-alpha', 'SII', 'OIII', 'S2', 'O3']) {
        expect(
          resolveCameraCaptureDefaults(cameraName: name, filterName: filter),
          (gain: 139, offset: 21),
        );
      }
    }
  });

  test(
    'other cameras use their own catalog and unknown models never borrow',
    () {
      expect(
        resolveCameraCaptureDefaults(
          cameraName: 'ZWO ASI2600MM Pro',
          filterName: 'Ha',
        ),
        (gain: 100, offset: 50),
      );
      expect(
        resolveCameraCaptureDefaults(
          cameraName: 'ASI1600MM Mystery',
          filterName: 'Ha',
        ),
        (gain: null, offset: null),
      );
      expect(
        resolveCameraCaptureDefaults(
          cameraName: 'Unknown',
          filterName: 'L',
          profileGain: 42,
          profileOffset: 8,
        ),
        (gain: 42, offset: 8),
      );
    },
  );

  test('library recipe edits round-trip and take precedence', () {
    const library = HardwarePresetsService();
    final original = library.matchCameraByName('ASI1600MM-Cool')!;
    final edited = original.copyWith(broadbandGain: 80, broadbandOffset: 16);
    final decoded = CameraDefaultsPreset.fromJson(edited.toJson());
    expect(decoded, edited);
    expect(decoded.hashCode, edited.hashCode);
    expect(
      resolveCameraCaptureDefaults(
        cameraName: 'ASI1600MM-Cool',
        filterName: 'R',
        library: library.withOverrides(cameraOverrides: [decoded]),
      ),
      (gain: 80, offset: 16),
    );
    expect(decoded.narrowbandGain, 139);
  });
}
