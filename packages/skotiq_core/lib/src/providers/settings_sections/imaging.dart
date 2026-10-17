// Image-output format defaults surfaced in Settings → Imaging. Owns the
// three knobs that affect how a captured frame is encoded on disk.
//
// Owns:
//   * imageFormat (currently FITS only)
//   * fileNamingPattern (template like `$TARGET_$FILTER_$DATE_$SEQ`)
//   * bitDepth (currently 16-bit only)
//
// Does NOT own:
//   * Save-path defaults → see `file_paths.dart`.
//   * Camera connect-time defaults (gain / offset / cooling) → see
//     `equipment.dart`.
//   * Live Pass/Reject grading → see `image_grading.dart`.
part of '../settings_provider.dart';

/// Capture files are currently persisted by `saveFitsFromLastCapture`, whose
/// native contract is 16-bit FITS. Keep unsupported choices out of both the UI
/// and persisted state until matching encoders exist; otherwise a `.tiff`,
/// `.xisf`, or `.png` filename can contain FITS bytes.
const String kCaptureImageFormat = 'FITS';
const String kCaptureBitDepth = '16-bit';
const List<String> kSupportedCaptureImageFormats = [kCaptureImageFormat];
const List<String> kSupportedCaptureBitDepths = [kCaptureBitDepth];

String _normalizeCaptureImageFormat(String _) => kCaptureImageFormat;
String _normalizeCaptureBitDepth(String _) => kCaptureBitDepth;

/// Setters for image-output format defaults.
extension ImagingSettingsSection on AppSettingsNotifier {
  Future<void> setImageFormat(String value) async {
    final normalized = _normalizeCaptureImageFormat(value);
    await _saveSetting('image_format', normalized);
    _patchState((s) => s.copyWith(imageFormat: normalized));
  }

  Future<void> setFileNamingPattern(String value) async {
    await _saveSetting('file_naming_pattern', value);
    _patchState((s) => s.copyWith(fileNamingPattern: value));
  }

  Future<void> setBitDepth(String value) async {
    final normalized = _normalizeCaptureBitDepth(value);
    await _saveSetting('bit_depth', normalized);
    _patchState((s) => s.copyWith(bitDepth: normalized));
  }
}
