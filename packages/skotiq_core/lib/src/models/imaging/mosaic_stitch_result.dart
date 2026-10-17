/// Value type mirroring the `api_stitch_mosaic` JSON result — the written mosaic
/// master path plus the output-canvas geometry and stitch diagnostics produced
/// when N plate-solved panel masters are projected onto a shared gnomonic canvas
/// and feather-blended into one master.
///
/// Pure, immutable value type with `fromJson`/`toJson` round-trip and value
/// equality, mirroring the native `StitchMosaicResult` (camelCase via serde
/// `rename_all`). Decoded defensively (nullable + defaults) so a partial payload
/// never throws.
library;

/// The result of a mosaic stitch. Mirrors the native `StitchMosaicResult`.
class MosaicStitchResult {
  /// Path the `F32` mosaic master was written to (native `outputPath`).
  final String outputPath;

  /// Path the `F32` per-pixel coverage plane was written to, when requested
  /// (native `coveragePath`); null otherwise.
  final String? coveragePath;

  /// Path the stretched preview PNG was written to, when requested; null
  /// otherwise.
  ///
  /// The native side names this `previewPngPath` (matching the sibling
  /// `drizzleIntegrate` envelope); the legacy `previewPath` key is also accepted
  /// so a thin wrapper renaming the field never breaks decoding.
  final String? previewPath;

  /// Output canvas width in pixels (native `outWidth`).
  final int outWidth;

  /// Output canvas height in pixels (native `outHeight`).
  final int outHeight;

  /// Number of overlapping panel pairs found (native `overlapPairs`).
  final int overlapPairs;

  /// Mean of the solved per-panel gains, a diagnostic of how hard the
  /// photometric normalization had to push the panels (native `meanPanelGain`).
  final double meanPanelGain;

  const MosaicStitchResult({
    required this.outputPath,
    this.coveragePath,
    this.previewPath,
    required this.outWidth,
    required this.outHeight,
    required this.overlapPairs,
    required this.meanPanelGain,
  });

  factory MosaicStitchResult.fromJson(Map<String, dynamic> json) {
    return MosaicStitchResult(
      outputPath: json['outputPath'] is String
          ? json['outputPath'] as String
          : '',
      coveragePath: json['coveragePath'] is String
          ? json['coveragePath'] as String
          : null,
      previewPath: json['previewPngPath'] is String
          ? json['previewPngPath'] as String
          : (json['previewPath'] is String
                ? json['previewPath'] as String
                : null),
      outWidth: _asInt(json['outWidth']),
      outHeight: _asInt(json['outHeight']),
      overlapPairs: _asInt(json['overlapPairs']),
      meanPanelGain: _asDouble(json['meanPanelGain']),
    );
  }

  Map<String, dynamic> toJson() => {
    'outputPath': outputPath,
    if (coveragePath != null) 'coveragePath': coveragePath,
    if (previewPath != null) 'previewPngPath': previewPath,
    'outWidth': outWidth,
    'outHeight': outHeight,
    'overlapPairs': overlapPairs,
    'meanPanelGain': meanPanelGain,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MosaicStitchResult &&
          other.outputPath == outputPath &&
          other.coveragePath == coveragePath &&
          other.previewPath == previewPath &&
          other.outWidth == outWidth &&
          other.outHeight == outHeight &&
          other.overlapPairs == overlapPairs &&
          other.meanPanelGain == meanPanelGain;

  @override
  int get hashCode => Object.hash(
    outputPath,
    coveragePath,
    previewPath,
    outWidth,
    outHeight,
    overlapPairs,
    meanPanelGain,
  );
}

double _asDouble(Object? v) => v is num ? v.toDouble() : 0.0;

int _asInt(Object? v) => v is num ? v.toInt() : 0;
