part of '../imaging_models.dart';

enum ImageFileFormat {
  fits,
  xisf,
  tiff,
  png,
  jpeg;

  String get extension {
    switch (this) {
      case ImageFileFormat.fits:
        return 'fits';
      case ImageFileFormat.xisf:
        return 'xisf';
      case ImageFileFormat.tiff:
        return 'tiff';
      case ImageFileFormat.png:
        return 'png';
      case ImageFileFormat.jpeg:
        return 'jpg';
    }
  }

  String get displayName {
    switch (this) {
      case ImageFileFormat.fits:
        return 'FITS';
      case ImageFileFormat.xisf:
        return 'XISF (PixInsight)';
      case ImageFileFormat.tiff:
        return 'TIFF';
      case ImageFileFormat.png:
        return 'PNG';
      case ImageFileFormat.jpeg:
        return 'JPEG';
    }
  }
}

extension ImageFileFormatSettingsX on ImageFileFormat {
  String get settingsValue {
    switch (this) {
      case ImageFileFormat.fits:
        return 'FITS';
      case ImageFileFormat.xisf:
        return 'XISF';
      case ImageFileFormat.tiff:
        return 'TIFF';
      case ImageFileFormat.png:
        return 'PNG';
      case ImageFileFormat.jpeg:
        return 'JPEG';
    }
  }

  static ImageFileFormat fromSettings(String value) {
    switch (value.toUpperCase()) {
      case 'XISF':
        return ImageFileFormat.xisf;
      case 'TIFF':
        return ImageFileFormat.tiff;
      case 'PNG':
        return ImageFileFormat.png;
      case 'JPEG':
        return ImageFileFormat.jpeg;
      case 'FITS':
      default:
        return ImageFileFormat.fits;
    }
  }
}

/// Progressive raw load state for host-authoritative capture previews.
enum RawLoadStatus { idle, loading, ready, failed }

/// Whether the preview pixels came from a local FFI backend or remote host.
enum CapturePreviewSource { local, remote }

/// Captured image data with display buffer
class CapturedImageData extends Equatable {
  final int width;
  final int height;
  final Uint8List displayData; // Always RGBA (width*height*4), alpha=255
  final List<int> histogram;
  final ImageStats stats;
  final DateTime capturedAt;
  final ExposureSettings settings;
  final String? targetName;
  final String? filePath;
  final bool
  isColor; // true if source was color (RGB), false if grayscale — displayData is always RGBA

  /// Host-authoritative 16-bit raw pixels (width * height), when loaded.
  final Uint16List? rawU16;

  /// Background raw fetch lifecycle (JPEG/display buffer is always shown first).
  final RawLoadStatus rawLoadStatus;

  /// Where the JPEG/display buffer was obtained.
  final CapturePreviewSource previewSource;

  const CapturedImageData({
    required this.width,
    required this.height,
    required this.displayData,
    required this.histogram,
    required this.stats,
    required this.capturedAt,
    required this.settings,
    this.targetName,
    this.filePath,
    this.isColor = false, // default to grayscale for backward compatibility
    this.rawU16,
    this.rawLoadStatus = RawLoadStatus.idle,
    this.previewSource = CapturePreviewSource.local,
  });

  bool get hasRawReady =>
      rawLoadStatus == RawLoadStatus.ready &&
      rawU16 != null &&
      rawU16!.length == width * height;

  CapturedImageData copyWith({
    int? width,
    int? height,
    Uint8List? displayData,
    List<int>? histogram,
    ImageStats? stats,
    DateTime? capturedAt,
    ExposureSettings? settings,
    String? targetName,
    String? filePath,
    bool? isColor,
    Uint16List? rawU16,
    RawLoadStatus? rawLoadStatus,
    CapturePreviewSource? previewSource,
    bool clearRawU16 = false,
  }) {
    return CapturedImageData(
      width: width ?? this.width,
      height: height ?? this.height,
      displayData: displayData ?? this.displayData,
      histogram: histogram ?? this.histogram,
      stats: stats ?? this.stats,
      capturedAt: capturedAt ?? this.capturedAt,
      settings: settings ?? this.settings,
      targetName: targetName ?? this.targetName,
      filePath: filePath ?? this.filePath,
      isColor: isColor ?? this.isColor,
      rawU16: clearRawU16 ? null : (rawU16 ?? this.rawU16),
      rawLoadStatus: rawLoadStatus ?? this.rawLoadStatus,
      previewSource: previewSource ?? this.previewSource,
    );
  }

  @override
  List<Object?> get props => [
    width,
    height,
    displayData,
    histogram,
    stats,
    capturedAt,
    settings,
    targetName,
    filePath,
    isColor,
    rawU16,
    rawLoadStatus,
    previewSource,
  ];
}

/// Captured image metadata (without pixel data)
class CapturedImage extends Equatable {
  final String id;
  final String filePath;
  final DateTime capturedAt;
  final ExposureSettings settings;
  final ImageStats? stats;
  final String? targetName;
  final ImageFileFormat format;

  const CapturedImage({
    required this.id,
    required this.filePath,
    required this.capturedAt,
    required this.settings,
    this.stats,
    this.targetName,
    this.format = ImageFileFormat.fits,
  });

  @override
  List<Object?> get props => [
    id,
    filePath,
    capturedAt,
    settings,
    stats,
    targetName,
    format,
  ];
}

/// Exposure progress
class ExposureProgress extends Equatable {
  final double elapsed;
  final double remaining;
  final double percent;
  final int frameNumber;
  final int? totalFrames;
  final bool isDownloading;

  const ExposureProgress({
    required this.elapsed,
    required this.remaining,
    required this.percent,
    this.frameNumber = 1,
    this.totalFrames,
    this.isDownloading = false,
  });

  factory ExposureProgress.idle() {
    return const ExposureProgress(
      elapsed: 0,
      remaining: 0,
      percent: 0,
      isDownloading: false,
    );
  }

  @override
  List<Object?> get props => [
    elapsed,
    remaining,
    percent,
    frameNumber,
    totalFrames,
    isDownloading,
  ];
}

/// Capture mode
enum CaptureMode {
  single,
  loop,
  count;

  String get displayName {
    switch (this) {
      case CaptureMode.single:
        return 'Single Frame';
      case CaptureMode.loop:
        return 'Loop';
      case CaptureMode.count:
        return 'Frame Count';
    }
  }
}
