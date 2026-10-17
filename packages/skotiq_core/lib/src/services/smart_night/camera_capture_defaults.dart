import '../../models/hardware_presets/hardware_preset_models.dart';
import '../hardware_presets/hardware_presets_service.dart';
import 'exposure_calculator.dart';

enum CaptureFilterGroup { broadband, narrowband }

CaptureFilterGroup captureFilterGroup(String filterName) =>
    FilterExposureSpec.fromName(filterName).category ==
        FilterCategory.narrowband
    ? CaptureFilterGroup.narrowband
    : CaptureFilterGroup.broadband;

/// Resolve only this camera's catalog values. Unknown cameras keep the
/// operator's profile values; they never borrow another model's gain scale.
({int? gain, int? offset}) resolveCameraCaptureDefaults({
  required String? cameraName,
  required String filterName,
  CameraDefaultsPreset? preset,
  int? profileGain,
  int? profileOffset,
  HardwarePresetsService library = const HardwarePresetsService(),
}) {
  final camera =
      preset ?? library.matchCameraByName(cameraName, exactOnly: true);
  if (camera == null) return (gain: profileGain, offset: profileOffset);
  final narrowband =
      captureFilterGroup(filterName) == CaptureFilterGroup.narrowband;
  return (
    gain:
        (narrowband ? camera.narrowbandGain : camera.broadbandGain) ??
        camera.recommendedGain,
    offset:
        (narrowband ? camera.narrowbandOffset : camera.broadbandOffset) ??
        camera.recommendedOffset,
  );
}
