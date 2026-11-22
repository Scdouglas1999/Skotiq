import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

/// Headless control surface for live stacking (real-time EAA integration).
///
/// The live stack runs on the HOST (the appliance that captures the frames);
/// pixel data never crosses the wire on the way in. A linked client drives it
/// through these endpoints: configure and start, then read the stacked
/// preview and stats.
///
/// The host has one live stack, [LiveStackingNotifier]: the routes drive it,
/// the host's screens show it, and a run feeds it every accepted light frame
/// while it is armed. So a stack a client arms keeps accumulating when the
/// client disconnects, and one the host started is the one the routes read.
class StackingHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    StackingApi.start: handleStart,
    StackingApi.startFilter: (Request request, String key) =>
        handleStart(request, _requiredSlot(key)),
    StackingApi.addFrame: handleAddFrame,
    StackingApi.updateConfig: handleUpdateConfig,
    StackingApi.reset: handleReset,
    StackingApi.resetFilter: (Request request, String key) =>
        handleReset(request, _requiredSlot(key)),
    StackingApi.stop: handleStop,
    StackingApi.stopFilter: (Request request, String key) =>
        handleStop(request, _requiredSlot(key)),
    StackingApi.status: handleStatus,
    StackingApi.stats: handleStats,
    StackingApi.result: handleResult,
    StackingApi.resultFilter: (Request request, String key) =>
        handleResult(request, _requiredSlot(key)),
    StackingApi.preview: handlePreview,
    StackingApi.previewFilter: (Request request, String key) =>
        handlePreview(request, _requiredSlot(key)),
    StackingApi.savedResults: handleSavedResults,
    StackingApi.savedResultPreview: handleSavedResultPreview,
    StackingApi.savedResult: handleSavedResult,
  };

  final ProviderContainer container;
  final Future<String> Function(int resultId) _savedPreviewPathResolver;

  StackingHandlers(
    this.container, {
    Future<String> Function(int resultId)? savedPreviewPathResolver,
  }) : _savedPreviewPathResolver =
           savedPreviewPathResolver ??
           ((resultId) => container
               .read(stackShareExportServiceProvider)
               .viewerPreviewPath(resultId));

  LiveStackingService get _service =>
      container.read(liveStackingServiceProvider);
  LiveStackingNotifier get _stack =>
      container.read(liveStackingProvider.notifier);
  LiveStackingState get _stackState => container.read(liveStackingProvider);
  StackedResultsDao get _resultsDao =>
      container.read(stackedResultsDaoProvider);

  /// Whether the stack is armed or running. One whose start failed is
  /// neither: a run's frames are not fed to it.
  bool get _armed => _stackState.status == LiveStackingStatus.running;

  /// Whether a reference frame has been established.
  bool get _started => _stackState.filterStacks.isNotEmpty;

  /// The settings a start without a `config` uses: the last ones a client
  /// sent.
  LiveStackingConfig _config = const LiveStackingConfig();

  /// Serializes the routes' operations, so a start's stop-then-arm is not
  /// interleaved with another request.
  Future<void> _chain = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final completer = _chain.then((_) => op());
    // Keep the chain alive even if this op throws, but don't swallow the
    // result the caller awaits.
    _chain = completer.then((_) {}, onError: (_) {});
    return completer;
  }

  Future<LiveStackingStats> _startReference(
    String referencePath,
    LiveStackingConfig config, {
    String? filterKey,
  }) async {
    try {
      await _stack.startFromFileOrThrow(
        referencePath,
        config: config,
        filterKey: filterKey,
      );
      final state = _stackState;
      final slot = filterKey == null
          ? null
          : normalizeLiveStackFilterKey(filterKey);
      return state.filterStacks[slot]?.stats ?? state.stats;
    } catch (error, stackTrace) {
      final match = RegExp(
        r'Reference frame has only (\d+) stars, need at least (\d+)',
      ).firstMatch(error.toString());
      if (match != null) {
        throw HandlerFailure(
          code: 'stacking_reference_rejected',
          message:
              'Reference frame does not contain enough stars for live-stack alignment.',
          statusCode: HttpStatus.unprocessableEntity,
          details: {
            'detectedStars': int.parse(match.group(1)!),
            'requiredStars': int.parse(match.group(2)!),
          },
          cause: error,
          stackTrace: stackTrace,
        );
      }
      rethrow;
    }
  }

  /// POST /api/stacking/start
  /// Body: `{ config?: {...}, referencePath?: "host-path" }`
  /// With a referencePath the stack starts immediately from that host frame.
  /// Without one, stacking is "armed": the next light frame a run saves
  /// becomes its filter's reference and later ones are added.
  Future<Response> handleStart(Request request, [String? slot]) async {
    // Arming with defaults needs no body, so tolerate an empty/absent one
    // rather than forcing clients to POST a bare `{}`.
    final payload = await readJsonObjectOrEmpty(request);
    final requestedConfig =
        _configFromJson(optionalObject(payload, 'config'), defaults: _config) ??
        _config;
    final rawReferencePath = optionalString(
      payload,
      'referencePath',
      maxLength: 4096,
    );
    final referencePath = rawReferencePath?.trim();
    // Absent, blank, or the "no filter" dash keeps the pre-filterKey meaning:
    // start the whole stack. Older clients never send the field.
    final filterKey = slot ?? _explicitFilterKey(payload);

    return _enqueue(() async {
      if (filterKey != null) {
        return _startNamedFilter(
          filterKey,
          referencePath: referencePath,
          config: requestedConfig,
        );
      }
      // Reset an existing stack before restarting.
      if (_armed || _service.isActive) {
        try {
          await _stack.stopOrThrow();
        } catch (e, stackTrace) {
          throw HandlerFailure(
            code: 'stacking_reset_failed',
            message: 'Live stacking could not be reset before starting.',
            statusCode: 500,
            cause: e,
            stackTrace: stackTrace,
          );
        }
      }
      _config = requestedConfig;
      if (referencePath != null && referencePath.isNotEmpty) {
        final stats = await _startReference(referencePath, _config);
        return jsonOk({'status': 'started', 'stats': _statsToJson(stats)});
      }
      await _stack.arm(config: _config);
      // Armed with no reference frame yet: nothing has stacked, so report a
      // complete zero-valued stats object. The remote client
      // ([NetworkBackend.stackingStart]) treats every start response as a
      // protocol-authority boundary and requires a well-formed `stats` — a
      // missing one is a protocol error, not an implicit zero — so it must
      // always be present, even in the armed branch.
      return jsonOk({
        'status': 'armed',
        'message':
            'Stacking armed; the next captured frame becomes the reference.',
        'stats': _statsToJson(const LiveStackingStats()),
      });
    });
  }

  /// POST /api/stacking/add-frame  Body: `{ imagePath: "host-path" }`
  /// Explicit client-driven add (host paths only — full-frame pixel upload is
  /// not supported remotely, matching the imaging-stats policy).
  Future<Response> handleAddFrame(Request request) async {
    final payload = await readJsonObject(request);
    final imagePath = requireString(
      payload,
      'imagePath',
      maxLength: 4096,
    ).trim();
    if (imagePath.isEmpty) {
      throw BadRequestError(
        field: 'imagePath',
        expected: 'non-empty string',
        message: 'imagePath must not be blank',
      );
    }
    return _enqueue(() async {
      if (!_started) {
        // An armed stack is already running and waits for its reference: the
        // frame starts the unfiltered slot in it.
        final stats = await _startReference(
          imagePath,
          _config,
          filterKey: _armed ? kDefaultLiveStackFilterKey : null,
        );
        return jsonOk({'status': 'started', 'stats': _statsToJson(stats)});
      }
      final LiveStackingResult result;
      try {
        result = await _stack.addFrameFromFileOrThrow(imagePath);
      } catch (e) {
        throw _classifyAddFrameFailure(e, imagePath);
      }
      return jsonOk({
        'status': 'added',
        'width': result.width,
        'height': result.height,
        'channels': result.channels,
        'stats': _statsToJson(result.stats),
      });
    });
  }

  /// Translate an add-frame failure into something a client can branch on.
  ///
  /// A frame the stacker declines is ORDINARY in live stacking — cloud, wind, a
  /// satellite trail, a bumped focuser. The native stacker says which by
  /// kind. Left to the error translator they would answer
  /// `500 internal_error`, which tells a remote client the host broke and
  /// invites a retry storm, indistinguishable from the stacker actually being
  /// broken. Anything else stays the error it was.
  Object _classifyAddFrameFailure(Object error, String imagePath) {
    final refusal = liveStackRefusalOf(error);
    if (refusal == null) return error;
    // Bodies keep the text the refusal had before it had a kind, and add the
    // engine's sentence.
    final legacy = refusal.legacyText;
    return switch (refusal.kind) {
      // Rejected for not matching the reference. Counted in
      // `rejectedAlignmentFailures`; the accumulation is untouched.
      LiveStackRefusalKind.misaligned => HandlerFailure(
        code: 'frame_rejected',
        message:
            'Frame did not align to the reference and was not stacked. The '
            'accumulation is unchanged; check tracking, focus and cloud.',
        statusCode: 422,
        details: {
          'imagePath': imagePath,
          'reason': legacy,
          'sentence': refusal.message,
        },
        cause: error,
      ),
      // Taken through another filter than the stack's: left out before any
      // alignment and counted in `otherFilterFrames`. The engine's sentence
      // names both filters.
      LiveStackRefusalKind.otherFilter => HandlerFailure(
        code: 'frame_other_filter',
        message: legacy.substring(legacy.indexOf(refusal.message)),
        statusCode: 422,
        details: {'imagePath': imagePath, 'sentence': refusal.message},
        cause: error,
      ),
      // A path the caller got wrong is the caller's error, not a host fault.
      LiveStackRefusalKind.unreadable => HandlerFailure(
        code: 'frame_unreadable',
        message: 'Could not read the frame at the supplied path.',
        statusCode: 404,
        details: {
          'imagePath': imagePath,
          'reason': legacy,
          'sentence': refusal.message,
        },
        cause: error,
      ),
    };
  }

  /// GET /api/stacking/status -> liveness + counters (cheap, no pixels).
  Future<Response> handleStatus(Request request) async {
    return jsonOk({
      'active': _service.isActive,
      'frameCount': _service.frameCount,
      'armed': _armed,
      'started': _started,
    });
  }

  /// GET /api/stacking/stats -> current accumulation stats.
  ///
  /// Before the first frame the native stacker isn't initialized, so querying
  /// it throws "not initialized". Armed-but-not-started simply has nothing
  /// accumulated yet — report zeroed stats rather than a 500.
  Future<Response> handleStats(Request request) async {
    if (!_started && !_service.isActive) {
      return jsonOk({'stats': _statsToJson(const LiveStackingStats())});
    }
    final stats = await _service.getStats();
    return jsonOk({'stats': _statsToJson(stats)});
  }

  /// GET /api/stacking/result -> dimensions + stats (the JSON header the client
  /// pairs with /api/stacking/preview to assemble a LiveStackingResult).
  Future<Response> handleResult(Request request, [String? slot]) async {
    if (!_service.isActive) {
      return jsonError(
        code: 'no_active_stack',
        message: 'Live stacking is not running.',
        statusCode: 404,
      );
    }
    final result = await _service.getCurrentResult(filterKey: slot);
    return jsonOk({
      'active': true,
      'width': result.width,
      'height': result.height,
      'channels': result.channels,
      'stats': _statsToJson(result.stats),
    });
  }

  /// GET /api/stacking/preview -> raw little-endian u16 pixel buffer
  /// (width*height*channels samples). Dimensions/channels are echoed in
  /// response headers so the client can decode without a second round-trip.
  Future<Response> handlePreview(Request request, [String? slot]) async {
    if (!_service.isActive) {
      return jsonError(
        code: 'no_active_stack',
        message: 'Live stacking is not running.',
        statusCode: 404,
      );
    }
    final result = await _service.getCurrentResult(filterKey: slot);
    final samples = Uint16List.fromList(result.data);
    final bytes = samples.buffer.asUint8List(
      samples.offsetInBytes,
      samples.lengthInBytes,
    );
    return contentResponse(
      bytes,
      contentType: 'application/octet-stream',
      contentLength: bytes.length,
      headers: {
        'x-stack-width': result.width.toString(),
        'x-stack-height': result.height.toString(),
        'x-stack-channels': result.channels.toString(),
        'x-stack-endian': 'little',
      },
    );
  }

  /// GET /api/stacking/results?limit=20 -> durable Stack-and-Share history.
  ///
  /// Host filesystem paths are deliberately omitted. Clients receive only
  /// provenance and a truthful `previewAvailable` flag, then fetch pixels from
  /// the authenticated preview endpoint below.
  Future<Response> handleSavedResults(Request request) async {
    final limit =
        optionalQueryInt(
          request.url.queryParameters,
          'limit',
          min: 1,
          max: 100,
        ) ??
        20;
    final results = await _resultsDao.getRecentResults(limit: limit);
    final encoded = <Map<String, Object?>>[];
    for (final result in results) {
      encoded.add(await _savedResultToJson(result));
    }
    return jsonOk({'results': encoded});
  }

  /// `GET /api/stacking/results/<resultId>` -> one durable result record.
  Future<Response> handleSavedResult(Request request, String resultId) async {
    final id = _parseSavedResultId(resultId);
    final result = await _resultsDao.getResultById(id);
    if (result == null) {
      return jsonError(
        code: 'stack_result_not_found',
        message: 'No stacked result exists for id $id.',
        statusCode: 404,
      );
    }
    return jsonOk({'result': await _savedResultToJson(result)});
  }

  /// `GET /api/stacking/results/<resultId>/preview` -> encoded PNG/JPEG bytes.
  ///
  /// The recorded path remains host-private. Missing legacy previews are a
  /// precise 404 rather than a 200 with empty bytes or a fabricated image.
  Future<Response> handleSavedResultPreview(
    Request request,
    String resultId,
  ) async {
    final id = _parseSavedResultId(resultId);
    final result = await _resultsDao.getResultById(id);
    if (result == null) {
      return jsonError(
        code: 'stack_result_not_found',
        message: 'No stacked result exists for id $id.',
        statusCode: 404,
      );
    }

    final path = await _resolveSavedPreview(result);
    if (path == null) {
      return _previewUnavailable(id);
    }
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      return _previewUnavailable(id);
    }

    final extension = file.uri.pathSegments.last.toLowerCase();
    final contentType = _previewContentType(extension);
    if (contentType == null) {
      return _previewUnavailable(id);
    }
    return streamResponse(
      file.openRead(),
      contentType: contentType,
      contentLength: stat.size,
      headers: {HttpHeaders.cacheControlHeader: 'private, max-age=60'},
    );
  }

  /// POST /api/stacking/config  Body: { config: {...} }
  /// Updates the config used for the next start. (The Rust stacker fixes its
  /// alignment parameters at start; changing mid-stack would invalidate the
  /// running integration, so this takes effect on the next start/restart.)
  Future<Response> handleUpdateConfig(Request request) async {
    final payload = await readJsonObject(request);
    final parsed = _configFromJson(
      optionalObject(payload, 'config'),
      defaults: _config,
    );
    if (parsed == null) {
      throw BadRequestError(
        field: 'config',
        expected: 'object',
        message: "Body must include a 'config' object",
      );
    }
    return _enqueue(() async {
      _config = parsed;
      return jsonOk({'status': 'ok', 'appliesOn': 'next-start'});
    });
  }

  /// POST /api/stacking/reset -> clear accumulation, keep armed.
  ///
  /// Like [handleStop], tolerates the armed-but-never-started case: there is
  /// nothing accumulated to clear, so the stack stays armed for a reference.
  ///
  /// A `filterKey` resets that slot and leaves the others, and the
  /// coordinator, alone. No key resets the whole stack.
  Future<Response> handleReset(Request request, [String? slot]) async {
    final filterKey =
        slot ?? _explicitFilterKey(await readJsonObjectOrEmpty(request));
    return _enqueue(() async {
      if (filterKey != null) {
        // A slot the stack does not hold is left alone.
        await _stack.resetFilter(filterKey, throwOnFailure: true);
        return jsonOk({'status': 'reset', 'filterKey': filterKey});
      }
      // The next saved frame establishes a new reference. Release every old
      // slot together before arming again; a native reset keeps its reference.
      if (_started || _service.isActive) {
        final wasArmed = _armed;
        // The stack keeps its own settings; POST /config applies at the next
        // start.
        final config = _stackState.config;
        await _stack.stopOrThrow();
        if (wasArmed) await _stack.arm(config: config);
      }
      return jsonOk({'status': 'reset'});
    });
  }

  /// POST /api/stacking/stop -> stop the stacker and disarm auto-feed.
  ///
  /// Tolerates the armed-but-never-started case: nothing was started, and the
  /// caller just wants stacking off.
  /// Implements the shared stop/abort no-op contract — see [kWasRunningField]:
  /// the armed/started/active state is known here, so the response reports
  /// which state was actually torn down rather than claiming a stack was
  /// stopped when none was running.
  Future<Response> handleStop(Request request, [String? slot]) async {
    final filterKey =
        slot ?? _explicitFilterKey(await readJsonObjectOrEmpty(request));
    return _enqueue(() async {
      if (filterKey != null) {
        return _stopNamedFilter(filterKey);
      }
      final wasRunning = _armed || _started || _service.isActive;
      if (wasRunning) await _stack.stop();
      return jsonOk({
        'status': 'stopped',
        kWasRunningField: wasRunning,
        if (!wasRunning)
          'message': 'Live stacking was not running; nothing to stop.',
      });
    });
  }

  /// A named filter on the wire. Missing, blank, and the "no filter" dash
  /// mean the whole stack, so a client that predates `filterKey` is unchanged.
  String? _explicitFilterKey(Map<String, dynamic> payload) {
    return explicitLiveStackFilterKey(
      optionalString(payload, 'filterKey', maxLength: 128),
    );
  }

  String _requiredSlot(String raw) {
    final key = explicitLiveStackFilterKey(raw);
    if (key == null || key.length > 128) {
      throw BadRequestError(
        field: 'filterKey',
        expected: 'a filter name of 1 to 128 characters',
        message: 'Choose a named filter slot.',
      );
    }
    return key;
  }

  /// Start one filter slot. Does not reset the other slots. Without a
  /// reference the stack is armed: the next saved frame of each filter
  /// starts that filter's slot.
  Future<Response> _startNamedFilter(
    String filterKey, {
    required String? referencePath,
    required LiveStackingConfig config,
  }) async {
    _config = config;
    if (referencePath != null && referencePath.isNotEmpty) {
      // A slot the stack already has starts again from the new reference.
      await _stack.stopFilter(filterKey, throwOnFailure: true);
      final stats = await _startReference(
        referencePath,
        config,
        filterKey: filterKey,
      );
      return jsonOk({'status': 'started', 'stats': _statsToJson(stats)});
    }
    await _stack.arm(config: config);
    return jsonOk({
      'status': 'armed',
      'message':
          'Stacking armed; the next captured frame becomes the reference.',
      'stats': _statsToJson(const LiveStackingStats()),
    });
  }

  /// Stop one filter slot. The session stays armed while any other slot is
  /// still active. A slot that was never started is a successful no-op.
  Future<Response> _stopNamedFilter(String filterKey) async {
    final stopped = _stackState.filterStacks.containsKey(
      normalizeLiveStackFilterKey(filterKey),
    );
    await _stack.stopFilter(filterKey, throwOnFailure: true);
    return jsonOk({
      'status': 'stopped',
      'filterKey': filterKey,
      kWasRunningField: stopped,
    });
  }

  int _parseSavedResultId(String raw) {
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      throw BadRequestError(
        field: 'resultId',
        expected: 'positive integer',
        message: 'resultId must be a positive integer.',
      );
    }
    return parsed;
  }

  Response _previewUnavailable(int id) {
    return jsonError(
      code: 'stack_result_preview_unavailable',
      message: 'Stacked result $id has no durable preview.',
      statusCode: 404,
    );
  }

  Future<Map<String, Object?>> _savedResultToJson(
    StackAndShareResult result,
  ) async {
    final id = result.id;
    if (id == null || id <= 0) {
      throw StateError('A saved stacked result is missing its database id.');
    }
    final previewAvailable = await _resolveSavedPreview(result) != null;
    return {
      'id': id,
      'sessionId': result.sessionId,
      'targetId': result.targetId,
      'targetName': result.targetName,
      'width': result.width,
      'height': result.height,
      'framesStacked': result.framesStacked,
      'framesAttempted': result.framesAttempted,
      'integrationSecs': result.integrationSecs,
      'avgAlignmentResidual': result.avgAlignmentResidual,
      'avgHfr': result.avgHfr,
      'filter': result.filter,
      'isColor': result.isColor,
      'channels': result.channels,
      'createdAt': result.createdAt.toUtc().toIso8601String(),
      'previewAvailable': previewAvailable,
    };
  }

  Future<String?> _resolveSavedPreview(StackAndShareResult result) async {
    final id = result.id;
    if (id != null && id > 0) {
      final canonical = await _savedPreviewPathResolver(id);
      if (_hasSavedPreview(canonical)) return canonical;
    }
    final recorded = result.exportedImagePath;
    return _hasSavedPreview(recorded) ? recorded : null;
  }

  bool _hasSavedPreview(String? path) {
    if (path == null || path.trim().isEmpty) return false;
    try {
      final file = File(path);
      return _previewContentType(path.toLowerCase()) != null &&
          file.existsSync() &&
          file.lengthSync() > 0;
    } on FileSystemException {
      return false;
    }
  }

  String? _previewContentType(String path) {
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    return null;
  }

  LiveStackingConfig? _configFromJson(
    Map<String, dynamic>? json, {
    required LiveStackingConfig defaults,
  }) {
    if (json == null) return null;
    final sensorMode =
        (optionalString(json, 'sensorMode', maxLength: 16) ??
                defaults.sensorMode)
            .toLowerCase();
    if (!const {'mono', 'osc', 'auto'}.contains(sensorMode)) {
      throw BadRequestError(
        field: 'sensorMode',
        expected: 'mono, osc, or auto',
      );
    }

    final patternSupplied = json.containsKey('bayerPattern');
    final rawPattern = optionalString(json, 'bayerPattern', maxLength: 8);
    final bayerPattern = !patternSupplied
        ? defaults.bayerPattern
        : rawPattern?.toUpperCase();
    if (bayerPattern != null &&
        !const {'RGGB', 'BGGR', 'GRBG', 'GBRG'}.contains(bayerPattern)) {
      throw BadRequestError(
        field: 'bayerPattern',
        expected: 'RGGB, BGGR, GRBG, or GBRG',
      );
    }

    final demosaicQuality =
        (optionalString(json, 'demosaicQuality', maxLength: 16) ??
                defaults.demosaicQuality)
            .toLowerCase();
    if (!const {'bilinear', 'vng', 'superpixel'}.contains(demosaicQuality)) {
      throw BadRequestError(
        field: 'demosaicQuality',
        expected: 'bilinear, vng, or superpixel',
      );
    }

    final maxMatchStars =
        optionalInt(json, 'maxMatchStars', min: 3, max: 10000) ??
        defaults.maxMatchStars;
    final minMatchedPairs =
        optionalInt(json, 'minMatchedPairs', min: 3, max: 100) ??
        defaults.minMatchedPairs;
    if (minMatchedPairs > maxMatchStars) {
      throw BadRequestError(
        field: 'minMatchedPairs',
        expected: 'integer no greater than maxMatchStars',
      );
    }

    return LiveStackingConfig(
      sigmaClipEnabled:
          optionalBool(json, 'sigmaClipEnabled') ?? defaults.sigmaClipEnabled,
      sigmaClipThreshold:
          optionalDouble(json, 'sigmaClipThreshold', min: 0.1, max: 20) ??
          defaults.sigmaClipThreshold,
      maxMatchStars: maxMatchStars,
      matchRadiusPx:
          optionalDouble(json, 'matchRadiusPx', min: 0.1, max: 1000) ??
          defaults.matchRadiusPx,
      matchFluxTolerance:
          optionalDouble(json, 'matchFluxTolerance', min: 0, max: 1) ??
          defaults.matchFluxTolerance,
      minMatchedPairs: minMatchedPairs,
      maxAlignmentResidualPx:
          optionalDouble(json, 'maxAlignmentResidualPx', min: 0.1, max: 50) ??
          defaults.maxAlignmentResidualPx,
      starDetectionSigma:
          optionalDouble(json, 'starDetectionSigma', min: 0.5, max: 50) ??
          defaults.starDetectionSigma,
      starDetectionMinSnr:
          optionalDouble(json, 'starDetectionMinSnr', min: 0.5, max: 500) ??
          defaults.starDetectionMinSnr,
      sensorMode: sensorMode,
      bayerPattern: bayerPattern,
      demosaicQuality: demosaicQuality,
      // The feeder's gates for the frames of this host's run. A key the
      // client sends null turns its gate off; a key it does not send keeps
      // the host's.
      separateByFilter:
          optionalBool(json, 'separateByFilter') ?? defaults.separateByFilter,
      autoFeedEnabled:
          optionalBool(json, 'autoFeedEnabled') ?? defaults.autoFeedEnabled,
      maxHfrPx: json.containsKey('maxHfrPx')
          ? optionalDouble(json, 'maxHfrPx', min: 0.1, max: 100)
          : defaults.maxHfrPx,
      minStarCount: json.containsKey('minStarCount')
          ? optionalInt(json, 'minStarCount', min: 1, max: 100000)
          : defaults.minStarCount,
    );
  }

  Map<String, Object?> _statsToJson(LiveStackingStats s) => s.toJson();
}
