part of '../network_backend.dart';

/// The live stack a linked imaging host builds from the frames it captures.
final class HostLiveStack {
  HostLiveStack(this._host);

  final NetworkBackend _host;

  /// Add a host-side frame to the running stack and return the refreshed
  /// result (dimensions + stats + stacked pixels).
  Future<LiveStackingResult> stackingAddFrame(String imagePath) async {
    await _host._post(StackingApi.addFrame, body: {'imagePath': imagePath});
    return stackingGetResult();
  }

  /// Fetch the current stacked result: dimensions + stats (JSON) plus the raw
  /// little-endian u16 pixel buffer (binary).
  ///
  /// Every field is required and validated: `width`/`height` must be positive
  /// integers, `channels` must be 1 or 3, `stats` must be complete, and the
  /// downloaded preview must be exactly `width * height * channels` u16 samples.
  /// A truncated, oversized, odd-length, or dimension-mismatched buffer throws
  /// rather than being displayed as a valid stack.
  Future<LiveStackingResult> stackingGetResult() async {
    const metaEndpoint = 'GET /api/stacking/result';
    const previewEndpoint = 'GET /api/stacking/preview';
    final meta = await _host._get(StackingApi.result);
    final width = _host._requireStackingInt(meta, 'width', metaEndpoint, min: 1);
    final height = _host._requireStackingInt(meta, 'height', metaEndpoint, min: 1);
    final channels = _host._requireStackingChannels(meta, metaEndpoint);
    final stats = _host._requireStackingStats(meta, metaEndpoint);

    final bytes = await _host._downloadBytes(StackingApi.preview);
    final samples = _host._decodeStackingPreview(
      bytes,
      width,
      height,
      channels,
      previewEndpoint,
    );

    return LiveStackingResult(
      width: width,
      height: height,
      channels: channels,
      data: samples,
      stats: stats,
    );
  }

  /// Current accumulation stats only (cheap; no pixels). Requires a complete
  /// stats object; a partial/malformed 200 throws rather than reporting zeros.
  Future<LiveStackingStats> stackingGetStats() async {
    final response = await _host._get(StackingApi.stats);
    return _host._requireStackingStats(response, 'GET /api/stacking/stats');
  }

  /// Clear the accumulation (host stays armed).
  Future<void> stackingReset() async {
    await _host._post(StackingApi.reset, body: const {});
  }

  /// Start (or arm) live stacking on the host. With [referencePath] (a host
  /// path) the stack starts immediately from that frame; without it the host
  /// arms and the next captured frame becomes the reference.
  ///
  /// Both branches return a complete stats object — an armed host reports a
  /// zero-valued (but fully populated) [LiveStackingStats] because nothing has
  /// stacked yet. A missing/malformed `stats` object is a protocol failure and
  /// throws rather than being manufactured as zero.
  Future<LiveStackingStats> stackingStart({
    String? referencePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    final response = await _host._post(
      StackingApi.start,
      body: {
        'config': _host._stackingConfigToJson(config),
        if (referencePath != null) 'referencePath': referencePath,
      },
    );
    return _host._requireStackingStats(response, 'POST /api/stacking/start');
  }

  /// Stop the stacker and disarm host auto-feed.
  Future<void> stackingStop() async {
    await _host._post(StackingApi.stop, body: const {});
  }

  /// Fetch recent durable Stack-and-Share results, newest first.
  Future<List<RemoteStackedResult>> stackingGetSavedResults({
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 100) {
      throw RangeError.range(limit, 1, 100, 'limit');
    }
    const endpoint = 'GET /api/stacking/results';
    final response = await _host._get(
      StackingApi.savedResults,
      query: {'limit': limit},
    );
    final rawResults = response['results'];
    if (rawResults is! List) {
      throw const FormatException(
        'GET /api/stacking/results response field `results` must be an array',
      );
    }
    final results = <RemoteStackedResult>[];
    for (var index = 0; index < rawResults.length; index++) {
      final raw = rawResults[index];
      if (raw is! Map) {
        throw FormatException(
          '$endpoint response result at index $index must be an object',
        );
      }
      results.add(
        _host._savedStackResultFromJson(
          Map<String, dynamic>.from(raw),
          '$endpoint result[$index]',
        ),
      );
    }
    return results;
  }

  /// Fetch one durable Stack-and-Share result without exposing host paths.
  Future<RemoteStackedResult> stackingGetSavedResult(int resultId) async {
    if (resultId <= 0) {
      throw ArgumentError.value(resultId, 'resultId', 'must be positive');
    }
    final endpoint = 'GET /api/stacking/results/$resultId';
    final response = await _host._get(
      StackingApi.savedResult,
      path: {'resultId': resultId},
    );
    final result = _host._requireStackingObject(response, 'result', endpoint);
    return _host._savedStackResultFromJson(result, endpoint);
  }

  /// Download the encoded durable preview for [resultId]. Decoding and exact
  /// dimension validation happen in the provider shared by local and remote
  /// result review.
  Future<Uint8List> stackingGetSavedResultPreview(int resultId) async {
    if (resultId <= 0) {
      throw ArgumentError.value(resultId, 'resultId', 'must be positive');
    }
    final endpoint = 'GET /api/stacking/results/$resultId/preview';
    final downloaded = await _host._downloadBytesWithHeaders(
      StackingApi.savedResultPreview,
      path: {'resultId': resultId},
    );
    final contentType = downloaded.headers['content-type']
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (contentType != 'image/png' && contentType != 'image/jpeg') {
      throw FormatException(
        '$endpoint returned unsupported content type `${contentType ?? 'missing'}`',
      );
    }
    if (downloaded.bytes.isEmpty) {
      throw FormatException('$endpoint returned an empty image');
    }
    const maxPreviewBytes = 256 * 1024 * 1024;
    if (downloaded.bytes.lengthInBytes > maxPreviewBytes) {
      throw FormatException(
        '$endpoint returned ${downloaded.bytes.lengthInBytes} bytes; the '
        'maximum supported preview size is $maxPreviewBytes',
      );
    }
    return downloaded.bytes;
  }
}
