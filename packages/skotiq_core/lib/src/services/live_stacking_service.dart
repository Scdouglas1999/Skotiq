import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:path/path.dart' as p;

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../providers/backend_provider.dart';
import '../services/logging_service.dart';

/// Configuration for the live stacking engine.
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

/// Statistics about the current stacking session.
class LiveStackingStats {
  final int stackedFrameCount;
  final int totalFramesAttempted;
  final int rejectedAlignmentFailures;
  final double avgMatchedPairs;
  final double avgAlignmentResidual;
  final int totalSigmaRejectedPixels;

  const LiveStackingStats({
    this.stackedFrameCount = 0,
    this.totalFramesAttempted = 0,
    this.rejectedAlignmentFailures = 0,
    this.avgMatchedPairs = 0.0,
    this.avgAlignmentResidual = 0.0,
    this.totalSigmaRejectedPixels = 0,
  });
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

/// Result from adding a frame to the live stack.
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

/// Service that wraps the native live stacking bridge calls.
///
/// The live stacking engine aligns and averages incoming frames in real time,
/// providing a continuously improving preview for EAA and outreach.
class LiveStackingService {
  final SkotiqBackend _backend;
  final LoggingService _logger;
  final SaveStackMasterFits _saveFitsMaster;

  LiveStackingService(
    Ref ref, {
    SkotiqBackend? backend,
    SaveStackMasterFits? saveFitsMaster,
  }) : _backend = backend ?? ref.read(backendProvider),
       _logger = ref.read(loggingServiceProvider),
       _saveFitsMaster = saveFitsMaster ?? bridge.apiStackingSaveMasterFits;

  /// The active NetworkBackend when running as a remote client (tablet talking
  /// to a headless appliance), else null. When non-null the stacker runs on the
  /// HOST and every operation routes over `/api/stacking/*` rather than the
  /// local FFI bridge (whose stacker is empty on a remote client).
  NetworkBackend? get _remote {
    final backend = _backend;
    return backend is NetworkBackend ? backend : null;
  }

  /// Arm host-side live stacking without a local reference frame: the next
  /// frame the host captures becomes the reference and subsequent frames are
  /// auto-fed. This is the remote entry point — the tablet has no local file to
  /// hand the host. Only valid on a remote (NetworkBackend) connection; locally
  /// the operator picks a reference file via [startFromFile].
  Future<LiveStackingStats> startArmed({
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    final remote = _remote;
    if (remote == null) {
      throw StateError(
        'startArmed is only valid on a remote connection; use startFromFile '
        'with a reference frame when running on the imaging host.',
      );
    }
    _logger.info(
      'Arming host-side live stacking',
      source: 'LiveStackingService',
    );
    return remote.stackingStart(config: config);
  }

  /// Start live stacking with a reference image file.
  ///
  /// The reference frame defines the coordinate system; all subsequent frames
  /// are star-matched and aligned to it.
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    _logger.info(
      'Starting live stacking from file: $referenceImagePath',
      source: 'LiveStackingService',
    );

    final remote = _remote;
    if (remote != null) {
      // On a remote client the path is a HOST path; the host starts its stacker.
      return remote.stackingStart(
        referencePath: referenceImagePath,
        config: config,
      );
    }

    final bridgeConfig = bridge.ApiLiveStackingConfig(
      sigmaClipEnabled: config.sigmaClipEnabled,
      sigmaClipThreshold: config.sigmaClipThreshold,
      maxMatchStars: config.maxMatchStars,
      matchRadiusPx: config.matchRadiusPx,
      matchFluxTolerance: config.matchFluxTolerance,
      minMatchedPairs: config.minMatchedPairs,
      sensorMode: config.sensorMode,
      bayerPattern: config.bayerPattern,
      demosaicQuality: config.demosaicQuality,
    );

    final result = await bridge.apiStackingStart(
      referenceImagePath: referenceImagePath,
      config: bridgeConfig,
    );

    return _convertStats(result);
  }

  /// Start live stacking from raw pixel data in memory.
  ///
  /// Used when the reference frame is already captured and available as u16 data.
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    _logger.info(
      'Starting live stacking from data: ${width}x$height',
      source: 'LiveStackingService',
    );

    if (_remote != null) {
      // Raw pixel upload to the host is intentionally unsupported (the host
      // captures and stacks its own frames). Remote clients arm the host
      // ([startArmed]) or pass a host reference path ([startFromFile]).
      throw StateError(
        'startFromData is not available on a remote connection; the imaging '
        'host stacks the frames it captures. Use startArmed() instead.',
      );
    }

    final bridgeConfig = bridge.ApiLiveStackingConfig(
      sigmaClipEnabled: config.sigmaClipEnabled,
      sigmaClipThreshold: config.sigmaClipThreshold,
      maxMatchStars: config.maxMatchStars,
      matchRadiusPx: config.matchRadiusPx,
      matchFluxTolerance: config.matchFluxTolerance,
      minMatchedPairs: config.minMatchedPairs,
      sensorMode: config.sensorMode,
      bayerPattern: config.bayerPattern,
      demosaicQuality: config.demosaicQuality,
    );

    final result = await bridge.apiStackingStartFromData(
      width: width,
      height: height,
      data: data,
      config: bridgeConfig,
    );

    return _convertStats(result);
  }

  /// Add a frame to the stack from a file path.
  ///
  /// Returns the current stacked result (can be displayed as a preview).
  ///
  /// A refusal (alignment residual too high, too few stars, wrong dimensions)
  /// arrives as [LiveStackingFrameRejected] carrying the engine's own tally,
  /// so the rejection is countable rather than invisible.
  Future<LiveStackingResult> addFrameFromFile(String imagePath) async {
    _logger.info(
      'Adding frame to stack: $imagePath',
      source: 'LiveStackingService',
    );

    return _asCountedRejection(() async {
      final remote = _remote;
      if (remote != null) {
        return remote.stackingAddFrame(imagePath);
      }

      final result = await bridge.apiStackingAddFrame(imagePath: imagePath);
      return _convertResult(result);
    });
  }

  /// Add a frame to the stack from raw pixel data.
  Future<LiveStackingResult> addFrameFromData({
    required int width,
    required int height,
    required List<int> data,
  }) async {
    if (_remote != null) {
      throw StateError(
        'addFrameFromData is not available on a remote connection; the imaging '
        'host stacks the frames it captures.',
      );
    }
    return _asCountedRejection(() async {
      final result = await bridge.apiStackingAddFrameFromData(
        width: width,
        height: height,
        data: data,
      );
      return _convertResult(result);
    });
  }

  /// Run an add-frame call, re-labelling a refusal as
  /// [LiveStackingFrameRejected] with the engine's post-refusal statistics.
  ///
  /// The stats read-back is best effort: if it fails too (the stacker was
  /// stopped underneath us, the host went away) the original error propagates
  /// unchanged rather than being replaced by a second, less informative one.
  Future<LiveStackingResult> _asCountedRejection(
    Future<LiveStackingResult> Function() add,
  ) async {
    try {
      return await add();
    } catch (error, stackTrace) {
      final LiveStackingStats stats;
      try {
        stats = await getStats();
      } catch (_) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      throw LiveStackingFrameRejected(reason: error.toString(), stats: stats);
    }
  }

  /// Get the current stacked result without adding a frame.
  Future<LiveStackingResult> getCurrentResult() async {
    final remote = _remote;
    if (remote != null) {
      return remote.stackingGetResult();
    }
    final result = await bridge.apiStackingGetResult();
    return _convertResult(result);
  }

  /// Display-ready RGBA8 render of a stacked buffer.
  ///
  /// Delegates to the app's shared MAD-based Screen-Transfer-Function
  /// auto-stretch (Rust `imaging/src/stretch.rs`) — the same curve the image
  /// viewer and Stack-and-Share use — so the live preview shows the star field
  /// the frames actually contain. A linear min/max map cannot: on a real light
  /// frame the maximum is a saturated star and the minimum is the sky floor,
  /// which crushes every background pixel and every faint star to black.
  ///
  /// [channels] is `1` for a luminance plane (`width * height` u16 samples) or
  /// `3` for interleaved RGB16 (`width * height * 3`). Any other value is an
  /// error rather than a guess: there is no display layout for it.
  Uint8List autoStretchPreview({
    required int width,
    required int height,
    required List<int> data,
    int channels = 1,
  }) {
    switch (channels) {
      case 1:
        return bridge.apiAutoStretchImage(
          width: width,
          height: height,
          data: data,
        );
      case 3:
        return bridge.apiAutoStretchColorImage(
          width: width,
          height: height,
          data: data,
        );
      default:
        throw ArgumentError.value(
          channels,
          'channels',
          'auto-stretch supports 1 (luminance) or 3 (interleaved RGB16) '
              'channels only',
        );
    }
  }

  /// Write the accumulated stacked master to [filePath].
  ///
  /// Reads the result out of the stacker FIRST, so this is safe to call
  /// immediately before [stop] (which releases the native accumulator and with
  /// it every stacked pixel). Callers that stop a session with frames in it
  /// must offer this: without it the only outcome of Stop is that the whole
  /// integration is destroyed.
  ///
  /// A `.fits` / `.fit` / `.fts` destination — and a destination with no
  /// extension at all — writes the FITS master: the native stacker writes its
  /// own accumulated pixels, with `EXPTIME` and `DATE-OBS` synthesized from the
  /// frames it folded. A `.png` destination still writes the rendered image
  /// (16-bit linear for mono, stretched RGBA for colour), which is what the UI
  /// preview shows. Anything else raises
  /// [LiveStackingMasterFormatUnsupported] rather than producing a file whose
  /// name says one format and whose contents say another.
  ///
  /// The FITS master is written by the in-process stacker, so it is a local
  /// path only: on a remote client the stack lives on the imaging host and only
  /// its pixels come over the wire.
  ///
  /// The returned [LiveStackingMasterSave] carries the path actually written,
  /// the form it took, and (for a FITS master) the integration and `DATE-OBS`
  /// that went into the header.
  Future<LiveStackingMasterSave> saveMaster({required String filePath}) async {
    final trimmed = filePath.trim();
    final requested = p.extension(trimmed).toLowerCase();
    const fitsExtensions = {'.fits', '.fit', '.fts'};
    final isFits = fitsExtensions.contains(requested);

    if (requested.isNotEmpty && !isFits && requested != '.png') {
      throw LiveStackingMasterFormatUnsupported(
        requested,
        reason:
            'the live stacker writes a FITS master of the integration or a '
            'PNG of the render, and nothing else',
      );
    }

    // No extension means "the data product": the FITS master locally, and the
    // render on a remote client, which is all a client can write.
    final wantsFits = isFits || (requested.isEmpty && _remote == null);
    if (wantsFits) {
      if (_remote != null) {
        throw LiveStackingMasterFormatUnsupported(
          requested,
          reason:
              'the stack is accumulating on the imaging host, so only the '
              'host can write its FITS master — this client has the pixels but '
              'not the stack',
        );
      }
      return _saveFitsMasterTo(
        requested.isEmpty ? p.setExtension(trimmed, '.fits') : trimmed,
      );
    }

    final result = await getCurrentResult();
    if (result.stats.stackedFrameCount <= 0 ||
        result.width <= 0 ||
        result.height <= 0) {
      throw StateError('There is no stacked master to save yet.');
    }

    final target = p.setExtension(p.withoutExtension(filePath.trim()), '.png');
    _logger.info(
      'Saving stacked master (${result.stats.stackedFrameCount} frames) to '
      '$target',
      source: 'LiveStackingService',
    );

    if (result.channels == 3) {
      await bridge.apiSaveRgbaPngFile(
        filePath: target,
        width: result.width,
        height: result.height,
        rgba: autoStretchPreview(
          width: result.width,
          height: result.height,
          data: result.data,
          channels: 3,
        ),
      );
      return LiveStackingMasterSave(
        filePath: target,
        stackedFrameCount: result.stats.stackedFrameCount,
        format: LiveStackingMasterFormat.stretchedColor8,
      );
    }

    await bridge.apiSavePngFile(
      filePath: target,
      width: result.width,
      height: result.height,
      data: result.data,
    );
    return LiveStackingMasterSave(
      filePath: target,
      stackedFrameCount: result.stats.stackedFrameCount,
      format: LiveStackingMasterFormat.linearMono16,
    );
  }

  /// Write the native stacker's accumulated master to [target] as FITS.
  ///
  /// The pixels never cross into Dart here: the stacker owns both the
  /// accumulator and the provenance the header is built from, so it writes the
  /// file itself.
  Future<LiveStackingMasterSave> _saveFitsMasterTo(String target) async {
    _logger.info(
      'Saving stacked FITS master to $target',
      source: 'LiveStackingService',
    );
    final master = await _saveFitsMaster(filePath: target);
    _logger.info(
      'Stacked FITS master written: ${master.filePath} '
      '(${master.stackedFrameCount} frames, '
      '${master.totalIntegrationSecs.toStringAsFixed(1)} s integration)',
      source: 'LiveStackingService',
    );
    return LiveStackingMasterSave(
      filePath: master.filePath,
      stackedFrameCount: master.stackedFrameCount,
      format: LiveStackingMasterFormat.fitsMaster,
      totalIntegrationSecs: master.totalIntegrationSecs,
      dateObs: master.dateObs,
    );
  }

  /// Get the current stacking statistics.
  Future<LiveStackingStats> getStats() async {
    final remote = _remote;
    if (remote != null) {
      return remote.stackingGetStats();
    }
    final result = await bridge.apiStackingGetStats();
    return _convertStats(result);
  }

  /// Reset the stacker, clearing accumulated data but keeping the reference.
  Future<void> reset() async {
    _logger.info('Resetting live stacker', source: 'LiveStackingService');
    final remote = _remote;
    if (remote != null) {
      await remote.stackingReset();
      return;
    }
    await bridge.apiStackingReset();
  }

  /// Stop live stacking and release all resources.
  Future<void> stop() async {
    _logger.info('Stopping live stacker', source: 'LiveStackingService');
    final remote = _remote;
    if (remote != null) {
      await remote.stackingStop();
      return;
    }
    await bridge.apiStackingStop();
  }

  /// Check if live stacking is currently active.
  bool get isActive => bridge.apiStackingIsActive();

  /// Get the current frame count.
  int get frameCount => bridge.apiStackingFrameCount();

  LiveStackingStats _convertStats(bridge.ApiLiveStackingStats bridgeStats) {
    return LiveStackingStats(
      stackedFrameCount: bridgeStats.stackedFrameCount,
      totalFramesAttempted: bridgeStats.totalFramesAttempted,
      rejectedAlignmentFailures: bridgeStats.rejectedAlignmentFailures,
      avgMatchedPairs: bridgeStats.avgMatchedPairs,
      avgAlignmentResidual: bridgeStats.avgAlignmentResidual,
      totalSigmaRejectedPixels: bridgeStats.totalSigmaRejectedPixels.toInt(),
    );
  }

  LiveStackingResult _convertResult(bridge.ApiLiveStackingResult bridgeResult) {
    return LiveStackingResult(
      width: bridgeResult.width,
      height: bridgeResult.height,
      channels: bridgeResult.channels,
      data: bridgeResult.data,
      stats: _convertStats(bridgeResult.stats),
    );
  }
}

/// Provider for the LiveStackingService.
final liveStackingServiceProvider = Provider<LiveStackingService>((ref) {
  final backend = ref.watch(backendProvider);
  return LiveStackingService(ref, backend: backend);
});
