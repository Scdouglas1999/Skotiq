import 'dart:typed_data';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

/// Default filter key when a frame carries no optical filter.
const String kDefaultLiveStackFilterKey = 'Unfiltered';

/// A requested slot. The literal "Unfiltered" names a real slot, while the
/// blank or dash selection lets the engine choose the active one.
String? explicitLiveStackFilterKey(String? raw) {
  final trimmed = raw?.trim();
  return trimmed == null || trimmed.isEmpty || trimmed == '—' ? null : trimmed;
}

String normalizeLiveStackFilterKey(String? raw) =>
    explicitLiveStackFilterKey(raw) ?? kDefaultLiveStackFilterKey;

/// Curated live stacking tuning profiles for one-click configuration.
enum LiveStackingPreset {
  balanced,
  strictQuality,
  faintField,
  fastEaa;

  String get label => switch (this) {
    LiveStackingPreset.balanced => 'Balanced',
    LiveStackingPreset.strictQuality => 'Strict quality',
    LiveStackingPreset.faintField => 'Faint field',
    LiveStackingPreset.fastEaa => 'Fast EAA',
  };

  String get summary => switch (this) {
    LiveStackingPreset.balanced =>
      '2.5σ clip, 2.0 px max residual — good default for most nights',
    LiveStackingPreset.strictQuality =>
      '2.0σ clip, 1.2 px max residual, 8+ stars — sharp stacks, rejects drift',
    LiveStackingPreset.faintField =>
      'Lower star threshold (3σ / SNR 5), wider 80 px match radius — narrowband & galaxy fields',
    LiveStackingPreset.fastEaa =>
      'Relaxed 3.5 px residual & 3.0σ clip — maximizes accepted short subs for outreach',
  };

  /// Apply this preset's alignment & rejection tuning onto [base], preserving
  /// sensor/OSC and filter-routing preferences.
  LiveStackingConfig applyTo(LiveStackingConfig base) {
    return switch (this) {
      LiveStackingPreset.balanced => base.copyWith(
        sigmaClipEnabled: true,
        sigmaClipThreshold: 2.5,
        maxMatchStars: 100,
        matchRadiusPx: 50.0,
        matchFluxTolerance: 0.7,
        minMatchedPairs: 5,
        maxAlignmentResidualPx: 2.0,
        starDetectionSigma: 4.0,
        starDetectionMinSnr: 8.0,
      ),
      LiveStackingPreset.strictQuality => base.copyWith(
        sigmaClipEnabled: true,
        sigmaClipThreshold: 2.0,
        maxMatchStars: 120,
        matchRadiusPx: 35.0,
        matchFluxTolerance: 0.55,
        minMatchedPairs: 8,
        maxAlignmentResidualPx: 1.2,
        starDetectionSigma: 4.5,
        starDetectionMinSnr: 10.0,
      ),
      LiveStackingPreset.faintField => base.copyWith(
        sigmaClipEnabled: true,
        sigmaClipThreshold: 2.5,
        maxMatchStars: 150,
        matchRadiusPx: 80.0,
        matchFluxTolerance: 0.85,
        minMatchedPairs: 4,
        maxAlignmentResidualPx: 2.5,
        starDetectionSigma: 3.0,
        starDetectionMinSnr: 5.0,
      ),
      LiveStackingPreset.fastEaa => base.copyWith(
        sigmaClipEnabled: true,
        sigmaClipThreshold: 3.0,
        maxMatchStars: 75,
        matchRadiusPx: 75.0,
        matchFluxTolerance: 0.8,
        minMatchedPairs: 4,
        maxAlignmentResidualPx: 3.5,
        starDetectionSigma: 3.5,
        starDetectionMinSnr: 6.0,
      ),
    };
  }
}

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

  /// Maximum RMS alignment residual (pixels) before a frame is rejected.
  final double maxAlignmentResidualPx;

  /// Star detection threshold above sky background in noise sigmas.
  final double starDetectionSigma;

  /// Minimum star SNR required for alignment detection.
  final double starDetectionMinSnr;

  /// When true, incoming frames are routed into independent per-filter live
  /// stacks (`L`, `R`, `G`, `B`, `Ha`, `OIII`, `SII`, etc.). When false, all
  /// frames stack into one combined session.
  final bool separateByFilter;

  /// Whether newly captured light frames (manual or sequenced) automatically
  /// feed into the active/armed live stack.
  final bool autoFeedEnabled;

  /// Optional HFR quality gate (pixels). Frames reporting an HFR above this
  /// ceiling are skipped before stacking. Null disables the gate.
  final double? maxHfrPx;

  /// Optional minimum star-count quality gate. Frames reporting fewer stars
  /// are skipped before stacking. Null disables the gate.
  final int? minStarCount;

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
    this.maxAlignmentResidualPx = 2.0,
    this.starDetectionSigma = 4.0,
    this.starDetectionMinSnr = 8.0,
    this.separateByFilter = true,
    this.autoFeedEnabled = true,
    this.maxHfrPx,
    this.minStarCount,
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
    maxAlignmentResidualPx: maxAlignmentResidualPx,
    starDetectionSigma: starDetectionSigma,
    starDetectionMinSnr: starDetectionMinSnr,
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
    double? maxAlignmentResidualPx,
    double? starDetectionSigma,
    double? starDetectionMinSnr,
    bool? separateByFilter,
    bool? autoFeedEnabled,
    double? maxHfrPx,
    bool clearMaxHfrPx = false,
    int? minStarCount,
    bool clearMinStarCount = false,
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
      maxAlignmentResidualPx:
          maxAlignmentResidualPx ?? this.maxAlignmentResidualPx,
      starDetectionSigma: starDetectionSigma ?? this.starDetectionSigma,
      starDetectionMinSnr: starDetectionMinSnr ?? this.starDetectionMinSnr,
      separateByFilter: separateByFilter ?? this.separateByFilter,
      autoFeedEnabled: autoFeedEnabled ?? this.autoFeedEnabled,
      maxHfrPx: clearMaxHfrPx ? null : (maxHfrPx ?? this.maxHfrPx),
      minStarCount: clearMinStarCount
          ? null
          : (minStarCount ?? this.minStarCount),
      sensorMode: sensorMode ?? this.sensorMode,
      bayerPattern: clearBayerPattern
          ? null
          : (bayerPattern ?? this.bayerPattern),
      demosaicQuality: demosaicQuality ?? this.demosaicQuality,
    );
  }

  /// Identify which preset matches this configuration, or null if customized.
  LiveStackingPreset? get matchedPreset {
    for (final preset in LiveStackingPreset.values) {
      final candidate = preset.applyTo(this);
      if (candidate == this) return preset;
    }
    return null;
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
          maxAlignmentResidualPx == other.maxAlignmentResidualPx &&
          starDetectionSigma == other.starDetectionSigma &&
          starDetectionMinSnr == other.starDetectionMinSnr &&
          separateByFilter == other.separateByFilter &&
          autoFeedEnabled == other.autoFeedEnabled &&
          maxHfrPx == other.maxHfrPx &&
          minStarCount == other.minStarCount &&
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
    maxAlignmentResidualPx,
    starDetectionSigma,
    starDetectionMinSnr,
    separateByFilter,
    autoFeedEnabled,
    maxHfrPx,
    minStarCount,
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
  final double totalIntegrationSecs;

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
    this.totalIntegrationSecs = 0.0,
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
      totalIntegrationSecs = s.totalIntegrationSecs,
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

/// Per-frame transparency record surfaced in the Live Stack Frame Log.
class LiveStackFrameEvent {
  final int sequenceIndex;
  final String filterKey;
  final String sourceLabel;
  final bool accepted;
  final String? rejectionReason;

  /// Null for a local rejection before a star count was available.
  final int? detectedStars;
  final int matchedPairs;
  final int inlierPairs;
  final double alignmentResidualPx;
  final double shiftXPx;
  final double shiftYPx;
  final double rotationDeg;
  final int sigmaRejectedPixels;
  final double? exposureSecs;
  final DateTime timestamp;

  const LiveStackFrameEvent({
    required this.sequenceIndex,
    required this.filterKey,
    required this.sourceLabel,
    required this.accepted,
    this.rejectionReason,
    this.detectedStars,
    this.matchedPairs = 0,
    this.inlierPairs = 0,
    this.alignmentResidualPx = 0.0,
    this.shiftXPx = 0.0,
    this.shiftYPx = 0.0,
    this.rotationDeg = 0.0,
    this.sigmaRejectedPixels = 0,
    this.exposureSecs,
    required this.timestamp,
  });

  LiveStackFrameEvent.fromBridge(bridge.ApiLiveStackFrameEvent e)
    : sequenceIndex = e.sequenceIndex,
      filterKey = e.filterKey,
      sourceLabel = e.sourceLabel,
      accepted = e.accepted,
      rejectionReason = e.rejectionReason,
      detectedStars = e.detectedStars,
      matchedPairs = e.matchedPairs,
      inlierPairs = e.inlierPairs,
      alignmentResidualPx = e.alignmentResidualPx,
      shiftXPx = e.shiftXPx,
      shiftYPx = e.shiftYPx,
      rotationDeg = e.rotationDeg,
      sigmaRejectedPixels = e.sigmaRejectedPixels.toInt(),
      exposureSecs = e.exposureSecs,
      timestamp = DateTime.fromMillisecondsSinceEpoch(
        e.timestampMs.toInt(),
        isUtc: true,
      );
}

/// Summary of one active per-filter stack slot reported by the native engine.
class LiveStackFilterSummary {
  final String filterKey;
  final int width;
  final int height;
  final int channels;
  final String? referenceImagePath;
  final int revision;
  final LiveStackingStats stats;

  const LiveStackFilterSummary({
    required this.filterKey,
    required this.width,
    required this.height,
    required this.channels,
    this.referenceImagePath,
    required this.revision,
    required this.stats,
  });

  LiveStackFilterSummary.fromBridge(bridge.ApiLiveStackFilterSummary s)
    : filterKey = s.filterKey,
      width = s.width,
      height = s.height,
      channels = s.channels,
      referenceImagePath = s.referenceImagePath,
      revision = s.revision.toInt(),
      stats = LiveStackingStats.fromBridge(s.stats);
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

  /// Which filter slot produced this result (e.g. `"L"`, `"Ha"`, `"Unfiltered"`).
  final String filterKey;

  /// Monotonic native revision incremented whenever the stack changes.
  final int revision;

  /// Per-frame alignment/clipping record for the frame just evaluated, when available.
  final LiveStackFrameEvent? lastEvent;

  const LiveStackingResult({
    required this.width,
    required this.height,
    this.channels = 1,
    required this.data,
    required this.stats,
    this.filterKey = kDefaultLiveStackFilterKey,
    this.revision = 0,
    this.lastEvent,
  });

  /// The native stacker's current stack.
  LiveStackingResult.fromBridge(bridge.ApiLiveStackingResult r)
    : width = r.width,
      height = r.height,
      channels = r.channels,
      data = r.data,
      stats = LiveStackingStats.fromBridge(r.stats),
      filterKey = r.filterKey,
      revision = r.revision.toInt(),
      lastEvent = r.lastEvent != null
          ? LiveStackFrameEvent.fromBridge(r.lastEvent!)
          : null;
}

/// Stretched RGBA8 preview frame returned from off-UI-thread Rust worker rendering.
class StretchedPreviewFrame {
  final int width;
  final int height;
  final int channels;
  final Uint8List rgba;

  const StretchedPreviewFrame({
    required this.width,
    required this.height,
    required this.channels,
    required this.rgba,
  });
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
