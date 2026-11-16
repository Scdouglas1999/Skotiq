import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

class LiveStackingConfig {
  /// Whether sigma clipping is enabled for pixel rejection.
  final bool sigmaClipEnabled;

  /// Sigma threshold for pixel rejection (e.g. 2.5 means reject > 2.5 sigma from mean).
  final double sigmaClipThreshold;

  /// Maximum number of stars to use for matching.
  final int maxMatchStars;

  /// Maximum distance in pixels for a star match to be valid.
  final double matchRadiusPx;

  /// Maximum flux ratio difference for a star match (0.0 to 1.0).
  final double matchFluxTolerance;

  /// Minimum number of matched star pairs required for alignment.
  final int minMatchedPairs;

  /// Sensor acquisition mode: `"mono"`, `"osc"`, or `"auto"` (case-insensitive
  /// on the native side).
  ///
  /// - `mono` — frames are single-channel luminance; never debayered.
  /// - `osc` — frames are a Bayer CFA mosaic that *must* be debayered to RGB;
  ///   an unresolvable pattern is a hard error native-side (no silent
  ///   mono-fallback that would scramble the colour mosaic).
  /// - `auto` — debayer only when the frame actually carries Bayer geometry
  ///   (or [bayerPattern] is supplied); otherwise treat as mono.
  ///
  /// Defaults to `"mono"`.
  final String sensorMode;

  /// Explicit Bayer pattern override (`"RGGB"`/`"BGGR"`/`"GRBG"`/`"GBRG"`).
  /// When `null`, OSC/auto sessions fall back to the pattern the reference
  /// frame declares via its FITS `BAYERPAT` geometry. An unrecognised string
  /// is a hard error native-side.
  final String? bayerPattern;

  /// Demosaic quality: `"bilinear"`, `"vng"`, or `"superpixel"`. Defaults to
  /// `"bilinear"`. An unrecognised value is a hard error native-side rather
  /// than a silent best-guess.
  final String demosaicQuality;

  const LiveStackingConfig({
    this.sigmaClipEnabled = true,
    this.sigmaClipThreshold = 2.5,
    this.maxMatchStars = 100,
    this.matchRadiusPx = 50.0,
    this.matchFluxTolerance = 0.7,
    this.minMatchedPairs = 5,
    this.sensorMode = 'mono',
    this.bayerPattern,
    this.demosaicQuality = 'bilinear',
  });

  /// The same settings as the native stacker takes them.
  bridge.ApiLiveStackingConfig toBridge() => bridge.ApiLiveStackingConfig(
    sigmaClipEnabled: sigmaClipEnabled,
    sigmaClipThreshold: sigmaClipThreshold,
    maxMatchStars: maxMatchStars,
    matchRadiusPx: matchRadiusPx,
    matchFluxTolerance: matchFluxTolerance,
    minMatchedPairs: minMatchedPairs,
    sensorMode: sensorMode,
    bayerPattern: bayerPattern,
    demosaicQuality: demosaicQuality,
  );

  LiveStackingConfig copyWith({
    bool? sigmaClipEnabled,
    double? sigmaClipThreshold,
    int? maxMatchStars,
    double? matchRadiusPx,
    double? matchFluxTolerance,
    int? minMatchedPairs,
    String? sensorMode,
    String? bayerPattern,
    bool clearBayerPattern = false,
    String? demosaicQuality,
  }) {
    return LiveStackingConfig(
      sigmaClipEnabled: sigmaClipEnabled ?? this.sigmaClipEnabled,
      sigmaClipThreshold: sigmaClipThreshold ?? this.sigmaClipThreshold,
      maxMatchStars: maxMatchStars ?? this.maxMatchStars,
      matchRadiusPx: matchRadiusPx ?? this.matchRadiusPx,
      matchFluxTolerance: matchFluxTolerance ?? this.matchFluxTolerance,
      minMatchedPairs: minMatchedPairs ?? this.minMatchedPairs,
      sensorMode: sensorMode ?? this.sensorMode,
      bayerPattern: clearBayerPattern
          ? null
          : (bayerPattern ?? this.bayerPattern),
      demosaicQuality: demosaicQuality ?? this.demosaicQuality,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveStackingConfig &&
          runtimeType == other.runtimeType &&
          sigmaClipEnabled == other.sigmaClipEnabled &&
          sigmaClipThreshold == other.sigmaClipThreshold &&
          maxMatchStars == other.maxMatchStars &&
          matchRadiusPx == other.matchRadiusPx &&
          matchFluxTolerance == other.matchFluxTolerance &&
          minMatchedPairs == other.minMatchedPairs &&
          sensorMode == other.sensorMode &&
          bayerPattern == other.bayerPattern &&
          demosaicQuality == other.demosaicQuality;

  @override
  int get hashCode => Object.hash(
    sigmaClipEnabled,
    sigmaClipThreshold,
    maxMatchStars,
    matchRadiusPx,
    matchFluxTolerance,
    minMatchedPairs,
    sensorMode,
    bayerPattern,
    demosaicQuality,
  );
}

class LiveStackingStats {
  final int stackedFrameCount;
  final int totalFramesAttempted;
  final int rejectedAlignmentFailures;
  final double avgMatchedPairs;
  final double avgAlignmentResidual;
  final int totalSigmaRejectedPixels;

  /// The filter the stack is of: its reference frame's. Null when that frame
  /// named none, and from a host that does not report it.
  final String? filter;

  /// Frames left out because they were taken through another filter than
  /// [filter]. They are not attempts: nothing was aligned.
  final int otherFilterFrames;

  /// The filter of the most recent such frame; null when it had none.
  final String? lastOtherFilter;

  const LiveStackingStats({
    this.stackedFrameCount = 0,
    this.totalFramesAttempted = 0,
    this.rejectedAlignmentFailures = 0,
    this.avgMatchedPairs = 0.0,
    this.avgAlignmentResidual = 0.0,
    this.totalSigmaRejectedPixels = 0,
    this.filter,
    this.otherFilterFrames = 0,
    this.lastOtherFilter,
  });

  /// The native stacker's tally.
  LiveStackingStats.fromBridge(bridge.ApiLiveStackingStats s)
    : stackedFrameCount = s.stackedFrameCount,
      totalFramesAttempted = s.totalFramesAttempted,
      rejectedAlignmentFailures = s.rejectedAlignmentFailures,
      avgMatchedPairs = s.avgMatchedPairs,
      avgAlignmentResidual = s.avgAlignmentResidual,
      totalSigmaRejectedPixels = s.totalSigmaRejectedPixels.toInt(),
      filter = s.filter,
      otherFilterFrames = s.otherFilterFrames,
      lastOtherFilter = s.lastOtherFilter;

  /// Why frames were left out of the stack for their filter and what to do
  /// about it; null when none were.
  String? get otherFilterNote {
    if (otherFilterFrames == 0) return null;
    final stack = filter == null ? 'unfiltered frames' : '$filter frames';
    final latest = lastOtherFilter == null
        ? 'no filter'
        : 'the $lastOtherFilter filter';
    return otherFilterFrames == 1
        ? 'It was taken with $latest and this stack is of $stack. To stack '
              'it, stop and start a new live stack.'
        : 'They were taken with another filter (most recently $latest) and '
              'this stack is of $stack. To stack them, stop and start a new '
              'live stack.';
  }
}

/// Thrown when the stacker refuses the frame it was handed.
///
/// A refusal is a *counted event*: the engine increments
/// `totalFramesAttempted` (and, for an alignment refusal,
/// `rejectedAlignmentFailures`) and only then returns the error, and this
/// exception carries those counters, so a caller that catches it reports the
/// refusal instead of the statistics of the last ACCEPTED frame.
///
/// [stats] is the engine's own tally read back immediately after the refusal,
/// so a caller can publish the truth without a second round trip.
class LiveStackingFrameRejected implements Exception {
  /// The engine's reason, verbatim (e.g. "Alignment residual too high:
  /// 37.11px (max 2.00px)").
  final String reason;

  /// Stacker statistics AFTER the refusal was counted.
  final LiveStackingStats stats;

  const LiveStackingFrameRejected({required this.reason, required this.stats});

  /// Renders as the engine's reason so existing user-facing messages that
  /// interpolate the caught error are unchanged.
  @override
  String toString() => reason;
}

class LiveStackingResult {
  final int width;
  final int height;

  /// Channel count of the stacked result: `1` for a monochrome session, `3`
  /// for an OSC/colour session. Callers use this to interpret [data] as a
  /// single luminance plane vs interleaved RGB16.
  final int channels;
  final List<int> data;
  final LiveStackingStats stats;

  const LiveStackingResult({
    required this.width,
    required this.height,
    this.channels = 1,
    required this.data,
    required this.stats,
  });

  /// The native stacker's current stack.
  LiveStackingResult.fromBridge(bridge.ApiLiveStackingResult r)
    : width = r.width,
      height = r.height,
      channels = r.channels,
      data = r.data,
      stats = LiveStackingStats.fromBridge(r.stats);
}

/// Format a stacked master was written in.
enum LiveStackingMasterFormat {
  /// The data product: a FITS master of the linear integration, carrying the
  /// frame count plus an `EXPTIME` / `DATE-OBS` synthesized native-side from
  /// the frames actually stacked.
  fitsMaster,

  /// 16-bit single-channel PNG holding the linear stacked pixels verbatim —
  /// the integration itself, re-stretchable in any processing tool, but with
  /// no header at all.
  linearMono16,

  /// 8-bit RGBA PNG of the auto-stretched colour integration. The 16-bit PNG
  /// writers in the imaging pipeline are single-plane, so an OSC render is
  /// written as the display image rather than as a scrambled mono plane.
  stretchedColor8,
}

/// Thrown when a stacked master is asked for in a format this stacker cannot
/// write.
///
/// The master is FITS (header, WCS, integration metadata). A format the writer
/// cannot produce is refused with the reason rather than written under a
/// swapped extension, which would hand the operator a picture where they asked
/// for a master.
class LiveStackingMasterFormatUnsupported implements Exception {
  /// The extension the caller asked for, lower-cased and including the dot.
  final String requestedExtension;

  /// Why this destination cannot be written — a wrong format is not the same
  /// problem as a stack that lives on another machine.
  final String reason;

  const LiveStackingMasterFormatUnsupported(
    this.requestedExtension, {
    required this.reason,
  });

  @override
  String toString() =>
      'A stacked master cannot be written as "$requestedExtension": $reason. '
      'Save it as .fits for the FITS master, .png for the rendered image, or '
      'use Stack & Share for a processed export.';
}

/// Where a stacked master was written, and in what form.
class LiveStackingMasterSave {
  final String filePath;
  final int stackedFrameCount;
  final LiveStackingMasterFormat format;

  /// The master's `EXPTIME` in seconds — Σ of the exposures the stacked frames
  /// reported. Null for a PNG (which carries no header); `0.0` for a FITS
  /// master whose frames reported no exposure at all.
  final double? totalIntegrationSecs;

  /// The master's `DATE-OBS` as written. Null for a PNG.
  final String? dateObs;

  const LiveStackingMasterSave({
    required this.filePath,
    required this.stackedFrameCount,
    required this.format,
    this.totalIntegrationSecs,
    this.dateObs,
  });
}

/// Writes the native stacker's accumulated master to `filePath` as FITS.
/// Injectable so the format routing can be tested without the native library.
typedef SaveStackMasterFits =
    Future<bridge.ApiLiveStackingMaster> Function({required String filePath});
