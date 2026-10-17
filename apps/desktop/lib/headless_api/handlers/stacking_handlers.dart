import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Headless control surface for live stacking (real-time EAA integration).
///
/// The live-stacking engine runs on the HOST (the appliance that captures the
/// frames) — pixel data never crosses the wire on the way *in*. A remote tablet
/// drives it through these endpoints: configure + start, then poll the stacked
/// preview/stats; the host auto-feeds each newly-saved frame into the stacker.
///
/// Why a host-side coordinator rather than client-driven add-frame: the primary
/// couch scenario is "watch my running sequence stack live". Sequencer captures
/// happen on the host with no client in the loop, so the host must feed the
/// stacker itself ([onImageSaved], wired to the `ImageSaved` event stream in
/// the server lifecycle). This also means stacking keeps accumulating even if
/// the tablet disconnects.
class StackingHandlers {
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
  LoggingService get _logger => container.read(loggingServiceProvider);
  StackedResultsDao get _resultsDao =>
      container.read(stackedResultsDaoProvider);

  // Coordinator state

  /// True once the client has started stacking and the host should feed frames.
  bool _armed = false;

  /// True once a reference frame has been established (the first fed frame in
  /// arm-mode, or the explicit reference path passed to [handleStart]).
  bool _started = false;

  LiveStackingConfig _config = const LiveStackingConfig();

  /// Serializes all stacker mutations (start/add/reset/stop) so an auto-fed
  /// frame can't race a client-initiated op or another frame. The Rust stacker
  /// is single-threaded; overlapping calls would interleave alignment state.
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
    LiveStackingConfig config,
  ) async {
    try {
      return await _service.startFromFile(
        referenceImagePath: referencePath,
        config: config,
      );
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

  // Host auto-feed hook

  /// Called by the server's `ImageSaved` event subscription for every frame the
  /// host writes to disk. No-op unless stacking is armed.
  Future<void> onImageSaved(String filePath) async {
    if (!_armed || filePath.isEmpty) return;
    await _enqueue(() async {
      try {
        if (!_started) {
          await _service.startFromFile(
            referenceImagePath: filePath,
            config: _config,
          );
          _started = true;
          _logger.info(
            '[stacking] reference frame established from $filePath',
            source: 'StackingHandlers',
          );
        } else {
          await _service.addFrameFromFile(filePath);
        }
      } catch (e) {
        // A single rejected frame (alignment failure, unreadable file) must not
        // tear down the stack — log and keep going.
        _logger.warning(
          '[stacking] auto-feed of $filePath failed: $e',
          source: 'StackingHandlers',
        );
      }
    });
  }

  // Endpoints

  /// POST /api/stacking/start
  /// Body: `{ config?: {...}, referencePath?: "host-path" }`
  /// With a referencePath the stack starts immediately from that host frame.
  /// Without one, stacking is "armed": the next saved frame becomes the
  /// reference and subsequent frames are added automatically.
  Future<Response> handleStart(Request request) async {
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

    return _enqueue(() async {
      // Reset an existing stack before restarting. A fresh armed start has not
      // initialized the native stacker yet, so there is nothing to clear.
      if (_started || _service.isActive) {
        try {
          await _service.reset();
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
      _armed = true;
      if (referencePath != null && referencePath.isNotEmpty) {
        final stats = await _startReference(referencePath, _config);
        _started = true;
        return jsonOk({'status': 'started', 'stats': _statsToJson(stats)});
      }
      _started = false;
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
        final stats = await _startReference(imagePath, _config);
        _armed = true;
        _started = true;
        return jsonOk({'status': 'started', 'stats': _statsToJson(stats)});
      }
      final LiveStackingResult result;
      try {
        result = await _service.addFrameFromFile(imagePath);
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
  /// satellite trail, a bumped focuser. The native layer raises these as
  /// unstructured failures that the error translator turns into
  /// `500 internal_error`, which tells a remote client the host broke and
  /// invites a retry storm; worse, it is indistinguishable from the stacker
  /// actually being broken, so a client cannot tell "skip this frame and carry
  /// on" from "stop and tell the operator". Mirrors the `guide_star_not_found`
  /// treatment in the guiding handlers.
  Object _classifyAddFrameFailure(Object error, String imagePath) {
    final text = error.toString().toLowerCase();

    // Rejected for not matching the reference. Counted in
    // `rejectedAlignmentFailures`; the accumulation is untouched.
    if (text.contains('alignment residual too high') ||
        text.contains('alignment failed') ||
        text.contains('insufficient') && text.contains('star')) {
      return HandlerFailure(
        code: 'frame_rejected',
        message:
            'Frame did not align to the reference and was not stacked. The '
            'accumulation is unchanged; check tracking, focus and cloud.',
        statusCode: 422,
        details: {'imagePath': imagePath, 'reason': error.toString()},
        cause: error,
      );
    }

    // A path the caller got wrong is the caller's error, not a host fault.
    if (text.contains('no such file') ||
        text.contains('failed to read frame') ||
        text.contains('not found')) {
      return HandlerFailure(
        code: 'frame_unreadable',
        message: 'Could not read the frame at the supplied path.',
        statusCode: 404,
        details: {'imagePath': imagePath, 'reason': error.toString()},
        cause: error,
      );
    }

    return error;
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
  Future<Response> handleResult(Request request) async {
    if (!_service.isActive) {
      return jsonError(
        code: 'no_active_stack',
        message: 'Live stacking is not running.',
        statusCode: 404,
      );
    }
    final result = await _service.getCurrentResult();
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
  Future<Response> handlePreview(Request request) async {
    if (!_service.isActive) {
      return jsonError(
        code: 'no_active_stack',
        message: 'Live stacking is not running.',
        statusCode: 404,
      );
    }
    final result = await _service.getCurrentResult();
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
  /// Like [handleStop], tolerates the armed-but-never-started case: with no
  /// reference frame yet the native stacker isn't initialized, so resetting the
  /// engine would throw "not initialized". There's nothing accumulated to
  /// clear, so we just drop back to the armed-waiting-for-reference state.
  Future<Response> handleReset(Request request) async {
    return _enqueue(() async {
      try {
        if (_started || _service.isActive) {
          await _service.reset();
        }
      } catch (e) {
        _logger.warning(
          '[stacking] reset on an uninitialized stacker ignored: $e',
          source: 'StackingHandlers',
        );
      } finally {
        _started = false;
      }
      return jsonOk({'status': 'reset'});
    });
  }

  /// POST /api/stacking/stop -> stop the stacker and disarm auto-feed.
  ///
  /// Tolerates the armed-but-never-started case: if no reference frame has
  /// landed yet the native stacker was never initialized, so calling stop on it
  /// throws "not initialized". That's not an error from the caller's view; they
  /// just want stacking off. Only stop the engine when it actually
  /// started, and always clear the coordinator's armed/started state.
  /// Implements the shared stop/abort no-op contract — see [kWasRunningField]:
  /// the armed/started/active state is known here, so the response reports
  /// which state was actually torn down rather than claiming a stack was
  /// stopped when none was running.
  Future<Response> handleStop(Request request) async {
    return _enqueue(() async {
      // Captured BEFORE the `finally` clears the flags, so it reflects the
      // state the caller actually found.
      final wasRunning = _armed || _started || _service.isActive;
      try {
        if (_started || _service.isActive) {
          await _service.stop();
        }
      } catch (e) {
        _logger.warning(
          '[stacking] stop on an uninitialized stacker ignored: $e',
          source: 'StackingHandlers',
        );
      } finally {
        _armed = false;
        _started = false;
      }
      return jsonOk({
        'status': 'stopped',
        kWasRunningField: wasRunning,
        if (!wasRunning)
          'message': 'Live stacking was not running; nothing to stop.',
      });
    });
  }

  // (de)serialization

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
      sensorMode: sensorMode,
      bayerPattern: bayerPattern,
      demosaicQuality: demosaicQuality,
    );
  }

  Map<String, Object?> _statsToJson(LiveStackingStats s) => {
    'stackedFrameCount': s.stackedFrameCount,
    'totalFramesAttempted': s.totalFramesAttempted,
    'rejectedAlignmentFailures': s.rejectedAlignmentFailures,
    'avgMatchedPairs': s.avgMatchedPairs,
    'avgAlignmentResidual': s.avgAlignmentResidual,
    'totalSigmaRejectedPixels': s.totalSigmaRejectedPixels,
  };
}
