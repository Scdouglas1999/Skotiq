import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
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

// Uint16List equality is identity: metadata copies of a frame share one scan.
// Auto-disposal releases the buffer and cancels work when the HUD goes away.
final _rawPreviewHistogramProvider = FutureProvider.autoDispose
    .family<List<int>?, Uint16List>((ref, raw) {
      var cancelled = false;
      ref.onDispose(() => cancelled = true);
      return histogram256FromRawU16(raw, isCancelled: () => cancelled);
    });

/// Live preview counts together with the scale they describe. Raw pixels
/// becoming ready does not turn the display histogram into raw ADU counts.
final previewDisplayHistogramProvider =
    Provider.autoDispose<({List<int> bins, bool isRaw})?>((ref) {
      final source = ref.watch(
        currentImageProvider.select(
          (image) => image == null
              ? null
              : (
                  raw: image.hasRawReady ? image.rawU16 : null,
                  display: image.histogram,
                ),
        ),
      );
      if (source == null) return null;
      final raw = source.raw;
      if (raw != null) {
        final bins = ref.watch(_rawPreviewHistogramProvider(raw)).valueOrNull;
        if (bins != null) return (bins: bins, isRaw: true);
      }
      return (bins: source.display, isRaw: false);
    });
