/// How captured frames are written to disk.
///
/// Both formats hold the same 16-bit pixels and the same metadata. XISF is
/// PixInsight's own format: its keywords and standard properties land in the
/// fields PixInsight reads, and it can compress losslessly.
library;

const String kCaptureImageFormat = 'FITS';
const String kCaptureImageFormatXisf = 'XISF';
const String kCaptureBitDepth = '16-bit';
const List<String> kSupportedCaptureImageFormats = [
  kCaptureImageFormat,
  kCaptureImageFormatXisf,
];
const List<String> kSupportedCaptureBitDepths = [kCaptureBitDepth];

String normalizeCaptureImageFormat(String value) {
  final upper = value.trim().toUpperCase();
  return kSupportedCaptureImageFormats.contains(upper)
      ? upper
      : kCaptureImageFormat;
}

String normalizeCaptureBitDepth(String _) => kCaptureBitDepth;

/// XISF compression choices, named as the XISF `compression` attribute names
/// them: the codec, and `+sh` when samples are byte-shuffled first.
const String kXisfCompressionNone = 'none';
const Map<String, String> kXisfCompressionLabels = {
  kXisfCompressionNone: 'None (fastest)',
  'zstd+sh': 'Zstandard, byte-shuffled (smallest)',
  'zstd': 'Zstandard',
  'lz4+sh': 'LZ4, byte-shuffled',
  'lz4': 'LZ4',
  'lz4hc+sh': 'LZ4-HC, byte-shuffled',
  'lz4hc': 'LZ4-HC',
  'zlib+sh': 'zlib, byte-shuffled',
  'zlib': 'zlib',
};

String normalizeXisfCompression(String value) {
  final lower = value.trim().toLowerCase();
  return kXisfCompressionLabels.containsKey(lower)
      ? lower
      : kXisfCompressionNone;
}

/// What is saved for a frame from a camera that delivers its own file (a
/// DSLR's or mirrorless body's raw file). Astronomy cameras deliver none and
/// always get the converted file.
enum CameraFileSaving {
  /// The app's archive file (FITS or XISF), the camera's file discarded.
  converted('converted', 'Archive file only'),

  /// The camera's file exactly as delivered, and no archive file.
  camera('camera', 'Camera raw only'),

  /// Both, side by side under one name.
  both('both', 'Camera raw and archive file');

  const CameraFileSaving(this.settingValue, this.label);

  /// The stored value, and what the native save reads.
  final String settingValue;
  final String label;

  static CameraFileSaving fromSetting(String value) => CameraFileSaving.values
      .firstWhere((s) => s.settingValue == value, orElse: () => converted);
}

String normalizeCameraFileSaving(String value) =>
    CameraFileSaving.fromSetting(value).settingValue;
