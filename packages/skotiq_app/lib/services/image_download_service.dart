import 'dart:io';

import 'package:skotiq_core/skotiq_core.dart';

import 'file_download_service.dart';

export 'file_download_service.dart'
    show DesktopSaveLocationPicker, MobileFileShare;

/// Result of a "download the full-resolution capture to this device" flow.
///
/// Why this service exists: the host exposes `GET /api/images/<id>/download`
/// (resumable, byte-streamed) and `NetworkBackend.downloadImage` is a robust
/// resumable client — but NOTHING in the UI ever called it. A phone paired to
/// the Pi could see 512px thumbnails yet had no way to pull the real
/// FITS/processed frame onto the device. This wires that gap with a single
/// reusable entry point (see `downloadImageToDevice`).
///
/// The destination handling (temp file → share sheet / save picker) is the
/// generic [downloadFileToDevice]; these aliases keep the image-flavoured
/// names its callers and tests use.
typedef ImageDownloadStatus = FileDownloadStatus;
typedef ImageDownloadOutcome = FileDownloadOutcome;

/// Download the full-resolution image [imageId] from the connected imaging
/// host to a temp file (streamed + resumable via
/// [ImagingBackend.downloadImage]) and then hand it to the user:
///
///   * Desktop (Linux/macOS/Windows): a native "Save as…" picker; the temp
///     file is moved to the chosen location.
///   * Mobile (Android/iOS): the system share sheet (`share_plus`) so the
///     operator can drop it into Photos, Files, Drive, etc.
///
/// This works over a remote pairing (the host streams the bytes) AND for a
/// local host (the client backend copies its own file). Progress is reported
/// through [onProgress] in `[0, 1]`.
Future<ImageDownloadOutcome> downloadImageToDevice({
  required ImagingBackend backend,
  required int imageId,
  required String fileName,
  void Function(double progress)? onProgress,
  // Test seams — default to the real platform behaviour.
  DesktopSaveLocationPicker? desktopSavePicker,
  MobileFileShare? mobileShare,
  Future<Directory> Function()? temporaryDirectory,
}) async {
  if (imageId <= 0) {
    return const ImageDownloadOutcome.failed('Image id is not valid.');
  }
  final safeName = fileName.trim().isEmpty ? 'capture-$imageId.fits' : fileName;
  return downloadFileToDevice(
    fileName: safeName,
    tempKey: '$imageId',
    fetch: (localPath, progress) => downloadImageBytesTo(
      backend: backend,
      imageId: imageId,
      localPath: localPath,
      onProgress: progress,
    ),
    onProgress: onProgress,
    desktopSavePicker: desktopSavePicker,
    mobileShare: mobileShare,
    temporaryDirectory: temporaryDirectory,
  );
}

/// Thin indirection over [ImagingBackend.downloadImage] so the destination
/// logic above is unit-testable against a fake backend without a real socket.
Future<void> downloadImageBytesTo({
  required ImagingBackend backend,
  required int imageId,
  required String localPath,
  void Function(double)? onProgress,
}) {
  return backend.downloadImage(imageId, localPath, onProgress: onProgress);
}
