/// Capture files are written by `saveFitsFromLastCapture`, whose native
/// contract is 16-bit FITS. Other choices stay out of the UI and out of stored
/// settings until matching encoders exist; otherwise a `.tiff`, `.xisf` or
/// `.png` filename can contain FITS bytes.
library;

const String kCaptureImageFormat = 'FITS';
const String kCaptureBitDepth = '16-bit';
const List<String> kSupportedCaptureImageFormats = [kCaptureImageFormat];
const List<String> kSupportedCaptureBitDepths = [kCaptureBitDepth];

String normalizeCaptureImageFormat(String _) => kCaptureImageFormat;
String normalizeCaptureBitDepth(String _) => kCaptureBitDepth;

/// What is saved for a frame from a camera that delivers its own file (a
/// DSLR's or mirrorless body's raw file). Astronomy cameras deliver none and
/// always get the converted file.
enum CameraFileSaving {
  /// The app's FITS file, the camera's file discarded.
  converted('converted', 'FITS only'),

  /// The camera's file exactly as delivered, and no FITS file.
  camera('camera', 'Camera raw only'),

  /// Both, side by side under one name.
  both('both', 'Camera raw and FITS');

  const CameraFileSaving(this.settingValue, this.label);

  /// The stored value, and what the native save reads.
  final String settingValue;
  final String label;

  static CameraFileSaving fromSetting(String value) => CameraFileSaving.values
      .firstWhere((s) => s.settingValue == value, orElse: () => converted);
}

String normalizeCameraFileSaving(String value) =>
    CameraFileSaving.fromSetting(value).settingValue;
