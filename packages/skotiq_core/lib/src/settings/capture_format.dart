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
