import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:path/path.dart' as p;

import '../utils/logging_service.dart';
import '../backend/network_backend.dart';
import '../providers/logging_service_provider.dart';
import '../models/imaging/live_stacking_models.dart';

/// Service that wraps the native live stacking bridge calls.
///
/// The live stacking engine aligns and averages incoming frames in real time,
/// providing a continuously improving preview for EAA and outreach.
class LiveStackingService {
  final LoggingService _logger;
  final SaveStackMasterFits _saveFitsMaster;

  /// The linked host's stacker, or null where the stacker is this process's.
  /// When set every operation routes over `/api/stacking/*`: the local FFI
  /// bridge's stacker is empty on a linked client.
  final HostLiveStack? _remote;

  LiveStackingService(
    Ref ref, {
    HostLiveStack? host,
    SaveStackMasterFits? saveFitsMaster,
  }) : _remote = host,
       _logger = ref.read(loggingServiceProvider),
       _saveFitsMaster = saveFitsMaster ?? bridge.apiStackingSaveMasterFits;

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

    final result = await bridge.apiStackingStart(
      referenceImagePath: referenceImagePath,
      config: config.toBridge(),
    );

    return LiveStackingStats.fromBridge(result);
  }

  /// Start live stacking for a dedicated optical filter slot.
  Future<LiveStackingStats> startFromFileForFilter({
    required String filterKey,
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    _logger.info(
      'Starting live stacking from file: $referenceImagePath (filter=$filterKey)',
      source: 'LiveStackingService',
    );

    final remote = _remote;
    if (remote != null) {
      return remote.stackingStart(
        referencePath: referenceImagePath,
        config: config,
        filterKey: filterKey,
      );
    }

    final result = await bridge.apiStackingStartForFilter(
      filterKey: filterKey,
      referenceImagePath: referenceImagePath,
      config: config.toBridge(),
    );

    return LiveStackingStats.fromBridge(result);
  }

  /// Start live stacking from raw pixel data in memory.
  ///
  /// Used when the reference frame is already captured and available as u16
  /// data carrying [pedestal] ADU (0 for none), which the stacker takes out.
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    required double pedestal,
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

    final result = await bridge.apiStackingStartFromData(
      width: width,
      height: height,
      data: data,
      pedestal: pedestal,
      config: config.toBridge(),
    );

    return LiveStackingStats.fromBridge(result);
  }

  /// Start live stacking from raw pixel data for a specific filter slot.
  Future<LiveStackingStats> startFromDataForFilter({
    required String filterKey,
    required int width,
    required int height,
    required List<int> data,
    double pedestal = 0.0,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    if (_remote != null) {
      throw StateError(
        'startFromDataForFilter is not available on a remote connection.',
      );
    }

    final result = await bridge.apiStackingStartFromDataForFilter(
      filterKey: filterKey,
      width: width,
      height: height,
      data: data,
      pedestal: pedestal,
      config: config.toBridge(),
    );

    return LiveStackingStats.fromBridge(result);
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
      return LiveStackingResult.fromBridge(result);
    });
  }

  /// Add a frame to a specific filter's live stack from a file path.
  Future<LiveStackingResult> addFrameFromFileForFilter(
    String imagePath, {
    required String filterKey,
  }) async {
    _logger.info(
      'Adding frame to $filterKey stack: $imagePath',
      source: 'LiveStackingService',
    );

    return _asCountedRejection(() async {
      final remote = _remote;
      if (remote != null) {
        return remote.stackingAddFrame(imagePath);
      }

      final result = await bridge.apiStackingAddFrameForFilter(
        filterKey: filterKey,
        imagePath: imagePath,
      );
      return LiveStackingResult.fromBridge(result);
    }, filterKey: filterKey);
  }

  /// Add a frame to the stack from raw pixel data carrying [pedestal] ADU.
  Future<LiveStackingResult> addFrameFromData({
    required int width,
    required int height,
    required List<int> data,
    required double pedestal,
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
        pedestal: pedestal,
      );
      return LiveStackingResult.fromBridge(result);
    });
  }

  /// Add a frame to a specific filter's stack from raw pixel data.
  Future<LiveStackingResult> addFrameFromDataForFilter({
    required String filterKey,
    required int width,
    required int height,
    required List<int> data,
    double pedestal = 0.0,
  }) async {
    if (_remote != null) {
      throw StateError(
        'addFrameFromDataForFilter is not available on a remote connection.',
      );
    }
    return _asCountedRejection(() async {
      final result = await bridge.apiStackingAddFrameFromDataForFilter(
        filterKey: filterKey,
        width: width,
        height: height,
        data: data,
        pedestal: pedestal,
      );
      return LiveStackingResult.fromBridge(result);
    }, filterKey: filterKey);
  }

  /// Run an add-frame call, re-labelling a refusal as
  /// [LiveStackingFrameRejected] with the engine's post-refusal statistics.
  ///
  /// The stats read-back is best effort: if it fails too (the stacker was
  /// stopped underneath us, the host went away) the original error propagates
  /// unchanged rather than being replaced by a second, less informative one.
  Future<LiveStackingResult> _asCountedRejection(
    Future<LiveStackingResult> Function() add, {
    String? filterKey,
  }) async {
    try {
      return await add();
    } catch (error, stackTrace) {
      final LiveStackingStats stats;
      try {
        stats = filterKey != null
            ? await getStatsForFilter(filterKey)
            : await getStats();
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
    return LiveStackingResult.fromBridge(result);
  }

  /// Get the current stacked result for a specific filter slot.
  Future<LiveStackingResult> getCurrentResultForFilter(String filterKey) async {
    final remote = _remote;
    if (remote != null) {
      return remote.stackingGetResult();
    }
    final result = await bridge.apiStackingGetResultForFilter(
      filterKey: filterKey,
    );
    return LiveStackingResult.fromBridge(result);
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

  /// Off-UI-thread auto-stretch with optional parallel area downscaling in Rust.
  ///
  /// Runs on the Rust worker pool rather than blocking the Flutter UI isolate.
  /// When [maxDimension] > 0, images larger than [maxDimension] on their longest
  /// edge are area-downsampled in parallel before applying the shared MAD STF.
  Future<StretchedPreviewFrame> autoStretchPreviewAsync({
    required int width,
    required int height,
    required List<int> data,
    int channels = 1,
    int maxDimension = 2048,
  }) async {
    if (channels != 1 && channels != 3) {
      throw ArgumentError.value(
        channels,
        'channels',
        'auto-stretch supports 1 (luminance) or 3 (interleaved RGB16) '
            'channels only',
      );
    }
    final result = await bridge.apiAutoStretchPreviewAsync(
      width: width,
      height: height,
      channels: channels,
      data: data,
      maxDimension: maxDimension,
    );
    return StretchedPreviewFrame(
      width: result.width,
      height: result.height,
      channels: result.channels,
      rgba: result.rgba,
    );
  }

  /// Render a downscaled, progressive-STF-stretched RGBA8 preview directly from
  /// an active native live stack slot on a background worker thread (cached per
  /// revision and [maxDimension]), avoiding full-resolution u16 FFI copies.
  Future<StretchedPreviewFrame> renderStackPreviewRgba({
    String? filterKey,
    int maxDimension = 2048,
  }) async {
    if (_remote != null) {
      throw StateError(
        'renderStackPreviewRgba reads the local native stacker and is not '
        'available on a remote connection.',
      );
    }
    final result = await bridge.apiStackingRenderPreviewRgba(
      filterKey: filterKey,
      maxDimension: maxDimension,
    );
    return StretchedPreviewFrame(
      width: result.width,
      height: result.height,
      channels: result.channels,
      rgba: result.rgba,
    );
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
  Future<LiveStackingMasterSave> saveMaster({required String filePath}) {
    return _saveMasterImpl(filePath: filePath);
  }

  /// Write a specific filter slot's accumulated master to [filePath].
  Future<LiveStackingMasterSave> saveMasterForFilter({
    required String filterKey,
    required String filePath,
  }) {
    return _saveMasterImpl(filePath: filePath, filterKey: filterKey);
  }

  Future<LiveStackingMasterSave> _saveMasterImpl({
    required String filePath,
    String? filterKey,
  }) async {
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
              'host can write its FITS master. This client has the pixels but '
              'not the stack',
        );
      }
      return _saveFitsMasterTo(
        requested.isEmpty ? p.setExtension(trimmed, '.fits') : trimmed,
        filterKey: filterKey,
      );
    }

    final result = filterKey != null
        ? await getCurrentResultForFilter(filterKey)
        : await getCurrentResult();
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
      final stretched = await autoStretchPreviewAsync(
        width: result.width,
        height: result.height,
        data: result.data,
        channels: 3,
        maxDimension: 0,
      );
      await bridge.apiSaveRgbaPngFile(
        filePath: target,
        width: stretched.width,
        height: stretched.height,
        rgba: stretched.rgba,
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
  Future<LiveStackingMasterSave> _saveFitsMasterTo(
    String target, {
    String? filterKey,
  }) async {
    _logger.info(
      'Saving stacked FITS master to $target (filter=${filterKey ?? "active"})',
      source: 'LiveStackingService',
    );
    final master = filterKey != null
        ? await bridge.apiStackingSaveMasterFitsForFilter(
            filterKey: filterKey,
            filePath: target,
          )
        : await _saveFitsMaster(filePath: target);
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

  Future<LiveStackingStats> getStats() async {
    final remote = _remote;
    if (remote != null) {
      return remote.stackingGetStats();
    }
    final result = await bridge.apiStackingGetStats();
    return LiveStackingStats.fromBridge(result);
  }

  /// Get stacking statistics for a specific filter slot.
  Future<LiveStackingStats> getStatsForFilter(String filterKey) async {
    final remote = _remote;
    if (remote != null) {
      return remote.stackingGetStats();
    }
    final result = await bridge.apiStackingGetStatsForFilter(
      filterKey: filterKey,
    );
    return LiveStackingStats.fromBridge(result);
  }

  /// List all active per-filter stacks on the local native engine.
  Future<List<LiveStackFilterSummary>> listFilters() async {
    if (_remote != null) return const [];
    final list = await bridge.apiStackingListFilters();
    return list.map(LiveStackFilterSummary.fromBridge).toList(growable: false);
  }

  /// Read recent per-frame alignment/rejection events (newest first).
  Future<List<LiveStackFrameEvent>> getEvents({String? filterKey}) async {
    if (_remote != null) return const [];
    final list = await bridge.apiStackingGetEvents(filterKey: filterKey);
    return list.map(LiveStackFrameEvent.fromBridge).toList(growable: false);
  }

  /// Apply runtime-mutable config changes to active native stack(s) without
  /// resetting accumulated frames.
  Future<void> updateLiveConfig(
    LiveStackingConfig config, {
    String? filterKey,
  }) async {
    if (_remote != null) return;
    await bridge.apiStackingUpdateConfig(
      filterKey: filterKey,
      config: config.toBridge(),
    );
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

  /// Reset a specific filter's live stacker.
  Future<void> resetForFilter(String filterKey) async {
    _logger.info(
      'Resetting live stacker for $filterKey',
      source: 'LiveStackingService',
    );
    final remote = _remote;
    if (remote != null) {
      await remote.stackingReset(filterKey: filterKey);
      return;
    }
    await bridge.apiStackingResetForFilter(filterKey: filterKey);
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

  /// Stop a single filter's live stack slot.
  Future<void> stopForFilter(String filterKey) async {
    _logger.info(
      'Stopping live stacker for $filterKey',
      source: 'LiveStackingService',
    );
    final remote = _remote;
    if (remote != null) {
      await remote.stackingStop(filterKey: filterKey);
      return;
    }
    await bridge.apiStackingStopForFilter(filterKey: filterKey);
  }

  bool get isActive => _remote == null && bridge.apiStackingIsActive();

  int get frameCount => _remote == null ? bridge.apiStackingFrameCount() : 0;
}
