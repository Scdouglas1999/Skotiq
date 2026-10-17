import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../models/imaging/color_calibration_result.dart';
import '../models/imaging/integration_curve.dart';
import '../models/imaging/mosaic_stitch_result.dart';
import '../models/imaging/star_photometry.dart';
import '../providers/backend_provider.dart';

/// Injectable seam over the four post-session batch-processing FFI functions
/// (`apiIntegrateSession`, `apiMasterAccumulate`, `apiBuildMasterFlat`,
/// `apiSaveFitsMaster`).
///
/// **Why this exists.** Those native entry points are free functions on the
/// generated bridge that take a single JSON string and return a JSON string.
/// Calling them directly from the orchestration services would make the
/// services' logic — calibration resolution, per-filter selection, record
/// persistence, multi-night dedup — only exercisable with the Rust dynamic
/// library loaded. This seam mirrors the sibling [StackingEngineSeam] /
/// `StackShareExportService` injection pattern: the production implementation
/// ([BridgePostSessionSeam]) forwards to the bridge, and tests substitute a
/// fake so the service bodies run end-to-end without native code.
///
/// The seam deliberately stays at the *JSON envelope* level (`Map` in,
/// decoded result out): the request shapes are documented on
/// [post_session.rs]'s arg structs, and the strongly-typed result classes below
/// model exactly what the native side returns. Keeping the boundary thin means
/// new native knobs ride inside the request map and never change this interface.
abstract class PostSessionSeam {
  /// One-shot batch integration of a sub list into a linear FITS master.
  ///
  /// [args] is the `IntegrateSessionArgs` JSON shape:
  /// `{ lightPaths, reference?, exposuresSec?, calibration, settings, output }`.
  Future<IntegrateSessionResult> integrateSession(Map<String, dynamic> args);

  /// Multi-night accumulating master. [args] must carry an `op` of
  /// `create` / `add` / `finalize` / `info` plus that op's fields.
  Future<MasterAccumulateResult> masterAccumulate(Map<String, dynamic> args);

  /// Build a unit-mean master flat from raw flats. [args] is the
  /// `BuildMasterFlatArgs` JSON shape.
  Future<BuildMasterFlatResult> buildMasterFlat(Map<String, dynamic> args);

  /// Re-export an in-memory pixel buffer as a FITS master. [args] is the
  /// `SaveFitsMasterArgs` JSON shape.
  Future<SaveFitsMasterResult> saveFitsMaster(Map<String, dynamic> args);

  // Smart Morning Report — Pillar 2 (optimizer) + Pillar 3 (finishing) +
  // algorithm-depth (drizzle / deconvolution / star reduction / narrowband).
  //
  // These wrap the `finishing_*` FFI functions. Each is JSON-in/typed-out, the
  // same thin-envelope contract as the four batch functions above.

  /// Predict the marginal-SNR integration curve + keep/cull recommendation from
  /// per-sub quality descriptors, weights, and exposures. Wraps
  /// `apiAnalyzeNight`; a pure analytic predictor (no pixels integrated).
  ///
  /// [qualities] are per-sub `{noise, background, snr, fwhm, eccentricity?,
  /// starCount}` maps, aligned to [weights] and [exposuresS].
  Future<IntegrationCurve> analyzeNight({
    required List<Map<String, dynamic>> qualities,
    required List<double> weights,
    required List<double> exposuresS,
    double? aggressiveness,
    int? minKeep,
  });

  /// Detect stars on a master and measure each one's per-channel
  /// background-subtracted aperture flux. Wraps `apiDetectStarsPhotometry`.
  Future<StarPhotometryResult> detectStarsPhotometry({
    required String inputFits,
    int? maxStars,
    int? aperture,
  });

  /// Solve a per-channel white balance from the Dart-matched colour-indexed
  /// stars and apply it, writing the rebalanced master. Wraps
  /// `apiColorCalibrate`.
  ///
  /// [matchedStars] are `{channelFlux: [...], catalogBv: ...}` maps.
  Future<ColorCalibrationResult> colorCalibrate({
    required String inputFits,
    required String outputFits,
    required int channels,
    double? whiteRefBv,
    required List<Map<String, dynamic>> matchedStars,
  });

  /// Fit + subtract a low-order background model, writing the flattened master.
  /// Wraps `apiExtractBackground`; returns the written master's `outputPath`.
  Future<String> extractBackground(Map<String, dynamic> args);

  /// Bounded Richardson–Lucy deconvolution preview. Wraps
  /// `apiDeconvolvePreview`; returns the written frame's `outputPath`.
  Future<String> deconvolvePreview(Map<String, dynamic> args);

  /// Mask-confined star-size reduction preview. Wraps `apiReduceStarsPreview`;
  /// returns the written frame's `outputPath`.
  Future<String> reduceStarsPreview(Map<String, dynamic> args);

  /// Drizzle (variable-pixel linear reconstruction) onto a scaled output grid.
  /// Wraps `apiDrizzleIntegrate`; returns the decoded result map
  /// (`{outputPath, coveragePath?, coveragePngPath?, outWidth, outHeight,
  /// channels}`).
  Future<Map<String, dynamic>> drizzleIntegrate(Map<String, dynamic> args);

  /// Linearly combine single-channel narrowband masters into an RGB composite.
  /// Wraps `apiCombineChannels`; returns the written composite's `outputPath`.
  Future<String> combineChannels(Map<String, dynamic> args);

  // Mosaic M2 — panel-mosaic stitching.
  //
  // Wraps the `api_stitch_mosaic` FFI. JSON-in / typed-out, the same thin
  // envelope contract as the functions above.

  /// Project N plate-solved panel masters onto a shared gnomonic canvas and
  /// feather-blend them into one mosaic master. Wraps `apiStitchMosaic`.
  ///
  /// [args] is the `StitchMosaicArgs` JSON shape:
  /// `{ panels: [{ fitsPath, wcs? }], config?, output: { mosaicFitsPath,
  /// coverageFitsPath?, previewPngPath? } }`. Returns the written master path,
  /// the output-canvas dimensions, and the stitch diagnostics.
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args);

  /// Live post-session integration progress.
  ///
  /// Yields `(phase, fraction)` records derived from the native
  /// `IntegrationProgress` imaging events as `api_integrate_session` runs its
  /// phases (calibrate → register → weight → normalize → integrate → write →
  /// preview), `fraction` rising 0.0 → 1.0. The production seam filters the
  /// backend event stream; fakes return a synthetic / empty stream.
  Stream<({String phase, double fraction})> integrationProgress();
}

/// Production [PostSessionSeam] that encodes each request to JSON, forwards to
/// the native bridge, and decodes the JSON result.
class BridgePostSessionSeam implements PostSessionSeam {
  /// Backend handle whose [SkotiqBackend.eventStream] supplies the
  /// `IntegrationProgress` events surfaced by [integrationProgress]. The request
  /// /response methods do not need it (they call the bridge free functions
  /// directly), so it stays optional — a seam constructed without a backend
  /// simply yields an empty progress stream.
  final SkotiqBackend? _backend;

  const BridgePostSessionSeam([this._backend]);

  /// The active [NetworkBackend] when this seam runs on a remote client (a
  /// tablet talking to a headless appliance), else null. When non-null every
  /// host-side compute op routes over `/api/post-session/*` — the host's Rust
  /// pipeline does the work on its own file paths — rather than the local FFI
  /// bridge (whose result would be computed against the *client's* filesystem,
  /// where the subs do not exist). This is the post-session twin of
  /// `LiveStackingService._remote`.
  NetworkBackend? get _remote {
    final backend = _backend;
    return backend is NetworkBackend ? backend : null;
  }

  @override
  Future<IntegrateSessionResult> integrateSession(
    Map<String, dynamic> args,
  ) async {
    final remote = _remote;
    if (remote != null) {
      return IntegrateSessionResult.fromJson(
        await remote.postSessionIntegrate(args),
      );
    }
    final out = await bridge.apiIntegrateSession(argsJson: jsonEncode(args));
    return IntegrateSessionResult.fromJson(_decodeObject(out));
  }

  @override
  Future<MasterAccumulateResult> masterAccumulate(
    Map<String, dynamic> args,
  ) async {
    final remote = _remote;
    if (remote != null) {
      return MasterAccumulateResult.fromJson(
        await remote.postSessionMasterAccumulate(args),
      );
    }
    final out = await bridge.apiMasterAccumulate(argsJson: jsonEncode(args));
    return MasterAccumulateResult.fromJson(_decodeObject(out));
  }

  @override
  Future<BuildMasterFlatResult> buildMasterFlat(
    Map<String, dynamic> args,
  ) async {
    final remote = _remote;
    if (remote != null) {
      return BuildMasterFlatResult.fromJson(
        await remote.postSessionBuildMasterFlat(args),
      );
    }
    final out = await bridge.apiBuildMasterFlat(argsJson: jsonEncode(args));
    return BuildMasterFlatResult.fromJson(_decodeObject(out));
  }

  @override
  Future<SaveFitsMasterResult> saveFitsMaster(Map<String, dynamic> args) async {
    final out = await bridge.apiSaveFitsMaster(argsJson: jsonEncode(args));
    return SaveFitsMasterResult.fromJson(_decodeObject(out));
  }

  @override
  Future<IntegrationCurve> analyzeNight({
    required List<Map<String, dynamic>> qualities,
    required List<double> weights,
    required List<double> exposuresS,
    double? aggressiveness,
    int? minKeep,
  }) async {
    final args = <String, dynamic>{
      'qualities': qualities,
      'weights': weights,
      'exposuresS': exposuresS,
      'optimizer': <String, dynamic>{
        if (aggressiveness != null) 'aggressiveness': aggressiveness,
        if (minKeep != null) 'minKeep': minKeep,
      },
    };
    final remote = _remote;
    if (remote != null) {
      return IntegrationCurve.fromJson(
        await remote.postSessionAnalyzeNight(args),
      );
    }
    final out = await bridge.apiAnalyzeNight(argsJson: jsonEncode(args));
    return IntegrationCurve.fromJson(_decodeObject(out));
  }

  @override
  Future<StarPhotometryResult> detectStarsPhotometry({
    required String inputFits,
    int? maxStars,
    int? aperture,
  }) async {
    final args = <String, dynamic>{
      'inputFits': inputFits,
      if (maxStars != null) 'maxStars': maxStars,
      if (aperture != null) 'aperture': aperture,
    };
    final remote = _remote;
    if (remote != null) {
      return StarPhotometryResult.fromJson(
        await remote.postSessionDetectStars(args),
      );
    }
    final out = await bridge.apiDetectStarsPhotometry(
      argsJson: jsonEncode(args),
    );
    return StarPhotometryResult.fromJson(_decodeObject(out));
  }

  @override
  Future<ColorCalibrationResult> colorCalibrate({
    required String inputFits,
    required String outputFits,
    required int channels,
    double? whiteRefBv,
    required List<Map<String, dynamic>> matchedStars,
  }) async {
    final args = <String, dynamic>{
      'inputFits': inputFits,
      'outputFits': outputFits,
      'channels': channels,
      if (whiteRefBv != null) 'whiteRefBv': whiteRefBv,
      'matchedStars': matchedStars,
    };
    final remote = _remote;
    if (remote != null) {
      return ColorCalibrationResult.fromJson(
        await remote.postSessionColorCalibrate(args),
      );
    }
    final out = await bridge.apiColorCalibrate(argsJson: jsonEncode(args));
    return ColorCalibrationResult.fromJson(_decodeObject(out));
  }

  @override
  Future<String> extractBackground(Map<String, dynamic> args) async {
    final remote = _remote;
    if (remote != null) {
      return _outputPathFromMap(
        await remote.postSessionExtractBackground(args),
      );
    }
    final out = await bridge.apiExtractBackground(argsJson: jsonEncode(args));
    return _decodeOutputPath(out);
  }

  @override
  Future<String> deconvolvePreview(Map<String, dynamic> args) async {
    final out = await bridge.apiDeconvolvePreview(argsJson: jsonEncode(args));
    return _decodeOutputPath(out);
  }

  @override
  Future<String> reduceStarsPreview(Map<String, dynamic> args) async {
    final out = await bridge.apiReduceStarsPreview(argsJson: jsonEncode(args));
    return _decodeOutputPath(out);
  }

  @override
  Future<Map<String, dynamic>> drizzleIntegrate(
    Map<String, dynamic> args,
  ) async {
    final remote = _remote;
    if (remote != null) {
      return remote.postSessionDrizzleIntegrate(args);
    }
    final out = await bridge.apiDrizzleIntegrate(argsJson: jsonEncode(args));
    return _decodeObject(out);
  }

  @override
  Future<String> combineChannels(Map<String, dynamic> args) async {
    final remote = _remote;
    if (remote != null) {
      return _outputPathFromMap(await remote.postSessionCombineChannels(args));
    }
    final out = await bridge.apiCombineChannels(argsJson: jsonEncode(args));
    return _decodeOutputPath(out);
  }

  @override
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async {
    final out = await bridge.apiStitchMosaic(argsJson: jsonEncode(args));
    return MosaicStitchResult.fromJson(_decodeObject(out));
  }

  @override
  Stream<({String phase, double fraction})> integrationProgress() {
    final backend = _backend;
    if (backend == null) return const Stream.empty();
    return backend.eventStream
        .where(
          (e) =>
              e.category == EventCategory.imaging &&
              e.eventType == 'IntegrationProgress',
        )
        .map(
          (e) => (
            phase: e.data['phase'] as String? ?? '',
            fraction: (e.data['fraction'] as num?)?.toDouble() ?? 0.0,
          ),
        );
  }

  /// Decode a `{outputPath}` envelope to its path string. Throws a
  /// [FormatException] when the native call returned a non-object or omitted
  /// the path, mirroring [_decodeObject]'s contract.
  String _decodeOutputPath(String json) {
    final obj = _decodeObject(json);
    final path = obj['outputPath'];
    if (path is String) return path;
    throw FormatException(
      'post-session native call returned no outputPath',
      json,
    );
  }

  /// Pull the `outputPath` out of an already-decoded result map (the remote
  /// job-result envelope), mirroring [_decodeOutputPath]'s string contract.
  String _outputPathFromMap(Map<String, dynamic> obj) {
    final path = obj['outputPath'];
    if (path is String) return path;
    throw FormatException(
      'post-session remote call returned no outputPath: $obj',
    );
  }

  Map<String, dynamic> _decodeObject(String json) {
    final decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) return decoded;
    throw FormatException(
      'post-session native call returned a non-object JSON payload',
      json,
    );
  }
}

/// One per-frame record from [IntegrateSessionResult] — what the cull UI shows.
class PerFrameRecord {
  /// On-disk path of the sub this record describes.
  final String path;

  /// Normalized integration weight in (0, 1], or 0 when the frame was dropped.
  final double weight;

  /// RMS registration residual in reference pixels, or null if not registered.
  final double? rmsResidualPx;

  /// Whether the frame contributed to the master.
  final bool accepted;

  /// Human-readable reason when [accepted] is false.
  final String? reason;

  /// Per-sub signal-to-noise proxy from this sub's own measured
  /// [FrameQuality] (aligned luminance), or null when not measured. Mirrors the
  /// native `PerFrameRecord.snr`; persisted to the v42
  /// `integrated_master_frames.snr` column for the Night Doctor.
  final double? snr;

  /// Per-sub robust noise σ (ADU) from this sub's own measured [FrameQuality],
  /// or null when not measured. Mirrors the native `PerFrameRecord.noise`.
  ///
  /// **Load-bearing for the Smart Morning Report:** the marginal-SNR optimizer
  /// (`apiAnalyzeNight`) skips any sub whose `noise <= 0` from its variance
  /// sums, so the improvement curve / `targetSnr` collapse to zero unless this
  /// rides through into the `qualities` map (`_analyzeAndStoreCurve`). Omitting
  /// it defaults to 0 across the FFI and kills the feature.
  final double? noise;

  /// Per-sub sky-background level (ADU) from this sub's own measured
  /// [FrameQuality], or null when not measured. Mirrors the native
  /// `PerFrameRecord.background`; carried alongside [noise] so the optimizer's
  /// quality descriptors are complete.
  final double? background;

  /// Per-sub detected star count from this sub's own measured [FrameQuality],
  /// or null when not measured. Mirrors the native `PerFrameRecord.starCount`.
  final int? starCount;

  /// Per-sub median star FWHM in px, or null when not measured. Mirrors the
  /// native `PerFrameRecord.fwhm`.
  final double? fwhm;

  /// Per-sub median star eccentricity (0 = round, →1 = trailed), or null when
  /// too few reliable stars were available. Mirrors the native
  /// `PerFrameRecord.eccentricity`.
  final double? eccentricity;

  /// The fitted **source→reference** registration transform, as the row-major
  /// 3×3 homogeneous matrix flattened to 9 elements `[m00, m01, m02, m10, m11,
  /// m12, m20, m21, m22]` — the exact wire shape `api_drizzle_integrate`'s
  /// `DrizzleFrameArgs.transform` consumes. Null when the sub failed
  /// registration (so it contributes nothing to a drizzle stack). Mirrors the
  /// native `PerFrameRecord.transform`.
  final List<double>? transform;

  /// The transform family (`"similarity"` / `"affine"` / `"homography"`),
  /// informational; null when [transform] is null. Mirrors the native
  /// `PerFrameRecord.transformKind`.
  final String? transformKind;

  const PerFrameRecord({
    required this.path,
    required this.weight,
    required this.rmsResidualPx,
    required this.accepted,
    required this.reason,
    this.snr,
    this.noise,
    this.background,
    this.starCount,
    this.fwhm,
    this.eccentricity,
    this.transform,
    this.transformKind,
  });

  factory PerFrameRecord.fromJson(Map<String, dynamic> json) {
    final rawTransform = json['transform'];
    return PerFrameRecord(
      path: json['path'] as String,
      weight: (json['weight'] as num?)?.toDouble() ?? 0.0,
      rmsResidualPx: (json['rmsResidualPx'] as num?)?.toDouble(),
      accepted: json['accepted'] as bool? ?? false,
      reason: json['reason'] as String?,
      snr: (json['snr'] as num?)?.toDouble(),
      noise: (json['noise'] as num?)?.toDouble(),
      background: (json['background'] as num?)?.toDouble(),
      starCount: (json['starCount'] as num?)?.toInt(),
      fwhm: (json['fwhm'] as num?)?.toDouble(),
      eccentricity: (json['eccentricity'] as num?)?.toDouble(),
      transform: rawTransform is List
          ? rawTransform
                .map((e) => (e as num).toDouble())
                .toList(growable: false)
          : null,
      transformKind: json['transformKind'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'weight': weight,
    'rmsResidualPx': rmsResidualPx,
    'accepted': accepted,
    'reason': reason,
    'snr': snr,
    'noise': noise,
    'background': background,
    'starCount': starCount,
    'fwhm': fwhm,
    'eccentricity': eccentricity,
    if (transform != null) 'transform': transform,
    if (transformKind != null) 'transformKind': transformKind,
  };
}

/// Decoded result of [PostSessionSeam.integrateSession].
class IntegrateSessionResult {
  final String masterFitsPath;
  final String? previewPath;

  /// Scientific per-pixel rejection-count FITS.
  final String? rejectionMapPath;

  /// Stretched PNG sibling for UI compositing.
  final String? rejectionMapPreviewPath;

  /// Scientific drizzle coverage/weight FITS.
  final String? coverageMapPath;

  /// Stretched PNG sibling for UI compositing.
  final String? coverageMapPreviewPath;
  final int framesIntegrated;
  final int framesRejected;
  final double totalIntegrationSec;

  /// Mean inlier RMS residual across registered subs (reference px).
  final double rmsResidual;
  final int width;
  final int height;
  final int channels;
  final List<PerFrameRecord> perFrameStats;

  /// The applied-masters calibration report the native side built from the
  /// files themselves: one entry per dark / flat / bias slot with its match
  /// quality, the dimensions that differ, the dimensions nothing could compare,
  /// and the staleness term. Null for a master integrated by a build that did
  /// not write one.
  ///
  /// Carried opaquely because the shape is the native
  /// `CalibrationReport`'s, and it is persisted verbatim into
  /// `integrated_masters.stats_json` so the morning report reads the same
  /// account after a restart that it would have read at integration time.
  final Map<String, dynamic>? calibration;

  const IntegrateSessionResult({
    required this.masterFitsPath,
    required this.previewPath,
    required this.rejectionMapPath,
    this.rejectionMapPreviewPath,
    this.coverageMapPath,
    this.coverageMapPreviewPath,
    required this.framesIntegrated,
    required this.framesRejected,
    required this.totalIntegrationSec,
    required this.rmsResidual,
    required this.width,
    required this.height,
    required this.channels,
    required this.perFrameStats,
    this.calibration,
  });

  factory IntegrateSessionResult.fromJson(Map<String, dynamic> json) {
    final frames = (json['perFrameStats'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PerFrameRecord.fromJson)
        .toList(growable: false);
    return IntegrateSessionResult(
      masterFitsPath: json['masterFitsPath'] as String,
      previewPath: json['previewPath'] as String?,
      rejectionMapPath: json['rejectionMapPath'] as String?,
      rejectionMapPreviewPath: json['rejectionMapPreviewPath'] as String?,
      coverageMapPath: json['coverageMapPath'] as String?,
      coverageMapPreviewPath: json['coverageMapPreviewPath'] as String?,
      framesIntegrated: (json['framesIntegrated'] as num?)?.toInt() ?? 0,
      framesRejected: (json['framesRejected'] as num?)?.toInt() ?? 0,
      totalIntegrationSec:
          (json['totalIntegrationSec'] as num?)?.toDouble() ?? 0.0,
      rmsResidual: (json['rmsResidual'] as num?)?.toDouble() ?? 0.0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 1,
      perFrameStats: frames,
      calibration: json['calibration'] is Map<String, dynamic>
          ? json['calibration'] as Map<String, dynamic>
          : null,
    );
  }
}

/// Decoded result of [PostSessionSeam.masterAccumulate] (all four ops share it).
class MasterAccumulateResult {
  final String sidecarPath;
  final String? masterPath;
  final String? previewPath;
  final int frameCount;
  final double totalIntegrationSec;
  final int width;
  final int height;
  final int channels;

  /// Frames added in this call (0 for create/finalize/info).
  final int framesAdded;

  /// Samples rejected by the online clip in this call.
  final int rejected;

  /// Per-frame integration weight for the frames folded in THIS `add` call, in
  /// `lightPaths` order (empty for create/finalize/info). Persisted per sub so
  /// the multi-night growth/best-night intelligence has real weights, not nulls.
  final List<double> frameWeights;

  const MasterAccumulateResult({
    required this.sidecarPath,
    required this.masterPath,
    required this.previewPath,
    required this.frameCount,
    required this.totalIntegrationSec,
    required this.width,
    required this.height,
    required this.channels,
    required this.framesAdded,
    required this.rejected,
    this.frameWeights = const [],
  });

  factory MasterAccumulateResult.fromJson(Map<String, dynamic> json) {
    return MasterAccumulateResult(
      sidecarPath: json['sidecarPath'] as String,
      masterPath: json['masterPath'] as String?,
      previewPath: json['previewPath'] as String?,
      frameCount: (json['frameCount'] as num?)?.toInt() ?? 0,
      totalIntegrationSec:
          (json['totalIntegrationSec'] as num?)?.toDouble() ?? 0.0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 1,
      framesAdded: (json['framesAdded'] as num?)?.toInt() ?? 0,
      rejected: (json['rejected'] as num?)?.toInt() ?? 0,
      frameWeights: [
        for (final w in (json['frameWeights'] as List<dynamic>? ?? const []))
          if (w is num) w.toDouble(),
      ],
    );
  }
}

/// Decoded result of [PostSessionSeam.buildMasterFlat].
class BuildMasterFlatResult {
  final String outputPath;
  final int frameCount;

  /// Pre-normalization mean (illumination level).
  final double inputMean;

  /// Post-normalization mean (≈ unit-mean target).
  final double outputMean;
  final int width;
  final int height;
  final int channels;
  final String outputBitDepth;

  const BuildMasterFlatResult({
    required this.outputPath,
    required this.frameCount,
    required this.inputMean,
    required this.outputMean,
    required this.width,
    required this.height,
    required this.channels,
    required this.outputBitDepth,
  });

  factory BuildMasterFlatResult.fromJson(Map<String, dynamic> json) {
    return BuildMasterFlatResult(
      outputPath: json['outputPath'] as String,
      frameCount: (json['frameCount'] as num?)?.toInt() ?? 0,
      inputMean: (json['inputMean'] as num?)?.toDouble() ?? 0.0,
      outputMean: (json['outputMean'] as num?)?.toDouble() ?? 0.0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 1,
      outputBitDepth: json['outputBitDepth'] as String? ?? 'f32',
    );
  }
}

/// Decoded result of [PostSessionSeam.saveFitsMaster].
class SaveFitsMasterResult {
  final String outputPath;
  final int width;
  final int height;
  final int channels;
  final String pixelType;

  const SaveFitsMasterResult({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.channels,
    required this.pixelType,
  });

  factory SaveFitsMasterResult.fromJson(Map<String, dynamic> json) {
    return SaveFitsMasterResult(
      outputPath: json['outputPath'] as String,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 1,
      pixelType: json['pixelType'] as String? ?? 'f32',
    );
  }
}

/// Provider for the production [PostSessionSeam]. Tests override this with a
/// fake so the orchestration services run end-to-end without native code.
///
/// The active backend is passed so [PostSessionSeam.integrationProgress] can
/// filter its event stream for the native `IntegrationProgress` events.
final postSessionSeamProvider = Provider<PostSessionSeam>((ref) {
  return BridgePostSessionSeam(ref.watch(backendProvider));
});
