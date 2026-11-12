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
