import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/imaging/imaging_models.dart';
import '../models/imaging/frame_files.dart';
import 'backend_provider.dart';
import 'linked_host.dart';
import '../services/imaging_service.dart';

final imagingServiceProvider = Provider<ImagingService>((ref) {
  // Capture is backend-owned. Rebuild the service when the active host
  // changes so callers can use service identity as an authority boundary.
  ref.watch(backendProvider);
  final service = ImagingService(
    ref,
    hostFiles: ref.watch(linkedHostFilesProvider),
    hostRecords: ref.watch(linkedHostImagingRecordsProvider),
  );
  ref.onDispose(service.retire);
  return service;
});

/// Whether the currently displayed image has been auto-calibrated.
///
/// Derived from `currentImageProvider.filePath`: the calibration service
/// writes calibrated frames with a `_cal.fits` suffix, and the imaging
/// service swaps the file path on the captured image data once the
/// calibration step succeeds (see `ImagingService.captureImage` —
/// auto-calibration block). When calibration fails or isn't enabled the
/// path stays at the original `.fits`, so the badge reflects only frames that
/// were actually calibrated.
final currentImageIsCalibratedProvider = Provider<bool>((ref) {
  final image = ref.watch(currentImageProvider);
  final path = image?.filePath;
  if (path == null || path.isEmpty) {
    return false;
  }
  // The calibration service names its output after the light with `_cal`
  // before the light's own extension.
  final lower = path.toLowerCase();
  return FrameFiles.isArchive(lower) &&
      lower.substring(0, lower.lastIndexOf('.')).endsWith('_cal');
});

/// Live preview histogram: uses host raw pixels when [CapturedImageData.hasRawReady],
/// otherwise the JPEG preview histogram bundled with the capture.
final previewDisplayHistogramProvider = Provider<List<int>?>((ref) {
  final image = ref.watch(currentImageProvider);
  if (image == null) {
    return null;
  }
  if (image.hasRawReady && image.rawU16 != null) {
    return histogram256FromRawU16(image.rawU16!);
  }
  return image.histogram;
});
