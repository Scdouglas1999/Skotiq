import 'dart:typed_data';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:path/path.dart' as p;

import '../utils/logging_service.dart';
import '../backend/network_backend.dart';
import '../models/imaging/live_stacking_models.dart';

/// The live stacker: this process's native stacker.
///
/// The live stacking engine aligns and averages incoming frames in real time,
/// providing a continuously improving preview for EAA and outreach. Every
/// stack operation takes an optional `filterKey`: null means the active
/// slot, a key means that filter's slot. [LinkedLiveStackingService] is the
/// same role on a linked client, where the stacker is the host's.
class LiveStackingService {
  final LoggingService _logger;
  final SaveStackMasterFits _saveFitsMaster;

  LiveStackingService(this._logger, {SaveStackMasterFits? saveFitsMaster})
    : _saveFitsMaster = saveFitsMaster ?? bridge.apiStackingSaveMasterFits;

  /// Whether the stack lives on a linked imaging host rather than here.
  bool get readsHost => false;

  /// Start live stacking with a reference image file.
  ///
  /// The reference frame defines the coordinate system; all subsequent frames
  /// are star-matched and aligned to it. Here a reference is required; a
  /// linked host also arms without one (the next frame it captures becomes
  /// the reference).
  Future<LiveStackingStats> start({
    String? referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
    String? filterKey,
  }) async {
    if (referenceImagePath == null) {
      throw StateError(
        'Live stacking on the imaging host starts from a reference frame.',
      );
    }
    _logger.info(
      'Starting live stacking from file: $referenceImagePath'
      '${filterKey != null ? ' (filter=$filterKey)' : ''}',
      source: 'LiveStackingService',
    );
    final result = filterKey != null
        ? await bridge.apiStackingStartForFilter(
            filterKey: filterKey,
            referenceImagePath: referenceImagePath,
            config: config.toBridge(),
          )
        : await bridge.apiStackingStart(
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
    double pedestal = 0.0,
    LiveStackingConfig config = const LiveStackingConfig(),
    String? filterKey,
  }) async {
    _logger.info(
      'Starting live stacking from data: ${width}x$height',
      source: 'LiveStackingService',
    );
    final result = filterKey != null
        ? await bridge.apiStackingStartFromDataForFilter(
            filterKey: filterKey,
            width: width,
            height: height,
            data: data,
            pedestal: pedestal,
            config: config.toBridge(),
          )
        : await bridge.apiStackingStartFromData(
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
  Future<LiveStackingResult> addFrameFromFile(
    String imagePath, {
    String? filterKey,
  }) async {
    _logger.info(
      filterKey != null
          ? 'Adding frame to $filterKey stack: $imagePath'
          : 'Adding frame to stack: $imagePath',
      source: 'LiveStackingService',
    );
    return _asCountedRejection(
      () => _addFrameFromFile(imagePath, filterKey: filterKey),
      filterKey: filterKey,
    );
  }

  Future<LiveStackingResult> _addFrameFromFile(
    String imagePath, {
    String? filterKey,
  }) async {
    final result = filterKey != null
        ? await bridge.apiStackingAddFrameForFilter(
            filterKey: filterKey,
            imagePath: imagePath,
          )
        : await bridge.apiStackingAddFrame(imagePath: imagePath);
    return LiveStackingResult.fromBridge(result);
  }

  /// Add a frame to the stack from raw pixel data carrying [pedestal] ADU.
  Future<LiveStackingResult> addFrameFromData({
    required int width,
    required int height,
    required List<int> data,
    double pedestal = 0.0,
    String? filterKey,
  }) {
    return _asCountedRejection(() async {
      final result = filterKey != null
          ? await bridge.apiStackingAddFrameFromDataForFilter(
              filterKey: filterKey,
              width: width,
              height: height,
              data: data,
              pedestal: pedestal,
            )
          : await bridge.apiStackingAddFrameFromData(
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
        stats = await getStats(filterKey: filterKey);
      } catch (_) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      throw LiveStackingFrameRejected(reason: error.toString(), stats: stats);
    }
  }

  /// The current stacked result without adding a frame.
  Future<LiveStackingResult> getCurrentResult({String? filterKey}) async {
    final result = filterKey != null
        ? await bridge.apiStackingGetResultForFilter(filterKey: filterKey)
        : await bridge.apiStackingGetResult();
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
  Future<LiveStackingMasterSave> saveMaster({
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
    final wantsFits = isFits || (requested.isEmpty && !readsHost);
    if (wantsFits) {
      if (readsHost) {
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

    final result = await getCurrentResult(filterKey: filterKey);
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

  Future<LiveStackingStats> getStats({String? filterKey}) async {
    final result = filterKey != null
        ? await bridge.apiStackingGetStatsForFilter(filterKey: filterKey)
        : await bridge.apiStackingGetStats();
    return LiveStackingStats.fromBridge(result);
  }

  /// List all active per-filter stacks on the local native engine.
  Future<List<LiveStackFilterSummary>> listFilters() async {
    final list = await bridge.apiStackingListFilters();
    return list.map(LiveStackFilterSummary.fromBridge).toList(growable: false);
  }

  /// Read recent per-frame alignment/rejection events (newest first).
  Future<List<LiveStackFrameEvent>> getEvents({String? filterKey}) async {
    final list = await bridge.apiStackingGetEvents(filterKey: filterKey);
    return list.map(LiveStackFrameEvent.fromBridge).toList(growable: false);
  }

  /// Apply runtime-mutable config changes to active native stack(s) without
  /// resetting accumulated frames.
  Future<void> updateLiveConfig(
    LiveStackingConfig config, {
    String? filterKey,
  }) async {
    await bridge.apiStackingUpdateConfig(
      filterKey: filterKey,
      config: config.toBridge(),
    );
  }

  /// Reset the stacker, clearing accumulated data but keeping the reference.
  Future<void> reset({String? filterKey}) async {
    _logger.info(
      'Resetting live stacker${filterKey != null ? ' for $filterKey' : ''}',
      source: 'LiveStackingService',
    );
    if (filterKey != null) {
      await bridge.apiStackingResetForFilter(filterKey: filterKey);
    } else {
      await bridge.apiStackingReset();
    }
  }

  /// Stop live stacking and release its resources.
  Future<void> stop({String? filterKey}) async {
    _logger.info(
      'Stopping live stacker${filterKey != null ? ' for $filterKey' : ''}',
      source: 'LiveStackingService',
    );
    if (filterKey != null) {
      await bridge.apiStackingStopForFilter(filterKey: filterKey);
    } else {
      await bridge.apiStackingStop();
    }
  }

  bool get isActive => bridge.apiStackingIsActive();

  int get frameCount => bridge.apiStackingFrameCount();
}

/// The live stacker on a linked client: the imaging host's, reached over
/// `/api/stacking/*`. This process's own native stacker is empty there.
///
/// Stretching and rendering a buffer still run here.
class LinkedLiveStackingService extends LiveStackingService {
  final HostLiveStack _host;

  LinkedLiveStackingService(super.logger, this._host, {super.saveFitsMaster});

  @override
  bool get readsHost => true;

  /// Without [referenceImagePath] the host arms and the next frame it
  /// captures becomes the reference; with one, it is a host path.
  @override
  Future<LiveStackingStats> start({
    String? referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
    String? filterKey,
  }) {
    _logger.info(
      referenceImagePath == null
          ? 'Arming host-side live stacking'
          : 'Starting live stacking from file: $referenceImagePath'
                '${filterKey != null ? ' (filter=$filterKey)' : ''}',
      source: 'LiveStackingService',
    );
    return _host.stackingStart(
      referencePath: referenceImagePath,
      config: config,
      filterKey: filterKey,
    );
  }

  /// Raw pixel upload to the host is not supported: the host stacks the
  /// frames it captures.
  @override
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    double pedestal = 0.0,
    LiveStackingConfig config = const LiveStackingConfig(),
    String? filterKey,
  }) async {
    throw StateError(
      'startFromData is not available on a remote connection; the imaging '
      'host stacks the frames it captures. Arm the host instead.',
    );
  }

  /// The host adds [imagePath] (a host path) to its active slot; the host
  /// route takes no filter.
  @override
  Future<LiveStackingResult> _addFrameFromFile(
    String imagePath, {
    String? filterKey,
  }) => _host.stackingAddFrame(imagePath);

  @override
  Future<LiveStackingResult> addFrameFromData({
    required int width,
    required int height,
    required List<int> data,
    double pedestal = 0.0,
    String? filterKey,
  }) async {
    throw StateError(
      'addFrameFromData is not available on a remote connection; the imaging '
      'host stacks the frames it captures.',
    );
  }

  @override
  Future<LiveStackingResult> getCurrentResult({String? filterKey}) =>
      _host.stackingGetResult(filterKey: filterKey);

  @override
  Future<StretchedPreviewFrame> renderStackPreviewRgba({
    String? filterKey,
    int maxDimension = 2048,
  }) async {
    throw StateError(
      'renderStackPreviewRgba reads the local native stacker and is not '
      'available on a remote connection.',
    );
  }

  /// The host's stats route has no filter: its active slot's tally.
  @override
  Future<LiveStackingStats> getStats({String? filterKey}) =>
      _host.stackingGetStats();

  @override
  Future<List<LiveStackFilterSummary>> listFilters() async => const [];

  @override
  Future<List<LiveStackFrameEvent>> getEvents({String? filterKey}) async =>
      const [];

  @override
  Future<void> updateLiveConfig(
    LiveStackingConfig config, {
    String? filterKey,
  }) async {}

  @override
  Future<void> reset({String? filterKey}) async {
    _logger.info(
      'Resetting live stacker${filterKey != null ? ' for $filterKey' : ''}',
      source: 'LiveStackingService',
    );
    await _host.stackingReset(filterKey: filterKey);
  }

  @override
  Future<void> stop({String? filterKey}) async {
    _logger.info(
      'Stopping live stacker${filterKey != null ? ' for $filterKey' : ''}',
      source: 'LiveStackingService',
    );
    await _host.stackingStop(filterKey: filterKey);
  }

  @override
  bool get isActive => false;

  @override
  int get frameCount => 0;
}
