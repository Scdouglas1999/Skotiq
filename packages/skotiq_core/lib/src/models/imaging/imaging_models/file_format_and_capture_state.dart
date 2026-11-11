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

/// Why the camera took a frame.
///
/// Every frame the camera reads out can be shown, but only a [capture] is a
/// frame of the night: the others are a means to an end. They are labeled
/// for what they are, and never counted as light frames, listed in the
/// session, or fed to the night's quality numbers.
enum FramePurpose {
  /// A frame taken to keep or to look at: a run's light, a snapshot, a loop.
  capture,

  /// A frame an autofocus run measured.
  autofocus,

  /// A frame taken to plate solve where the mount points.
  plateSolve,

  /// A frame a centering run solved to correct the pointing.
  centering,

  /// A frame a polar alignment run solved.
  polarAlignment;

  /// True for a frame that is a means, not a product.
  bool get isUtility => this != FramePurpose.capture;
}

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

  /// Why the camera took this frame.
  final FramePurpose purpose;

  /// The step of the run that took it (autofocus point 5, centering attempt
  /// 2), when the run has steps; null otherwise.
  final int? purposeStep;

  /// How many steps that run has; null when unknown.
  final int? purposeSteps;

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
    this.purpose = FramePurpose.capture,
    this.purposeStep,
    this.purposeSteps,
  });

  /// True for an autofocus, solve, centering or alignment frame.
  bool get isUtilityFrame => purpose.isUtility;

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
    FramePurpose? purpose,
    int? purposeStep,
    int? purposeSteps,
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
      purpose: purpose ?? this.purpose,
      purposeStep: purposeStep ?? this.purposeStep,
      purposeSteps: purposeSteps ?? this.purposeSteps,
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
    purpose,
    purposeStep,
    purposeSteps,
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
