part of '../network_backend.dart';

/// Remote (REST) client for the host's live-stacking control surface.
///
/// The stacking engine runs on the appliance; these calls drive it over
/// `/api/stacking/*`. The stacked preview comes back as a raw little-endian
/// u16 buffer ([stackingGetResult]); dimensions + stats arrive as JSON so the
/// buffer can be decoded without a header round-trip.
///
/// This is a *protocol-authority* boundary: the mobile companion trusts nothing
/// but a complete, well-typed response. A 200 with missing or malformed fields
/// is a protocol failure, never a legitimate "idle host" or "empty stack"
/// signal — decoding therefore fails loudly with an endpoint-aware
/// [FormatException] rather than manufacturing a plausible zero/idle result.
/// The one genuine idle signal — the host answering `/api/stacking/result` (or
/// `/preview`) with a `no_active_stack` 404 — is surfaced by the transport
/// layer ([_get]/[_downloadBytes] throw on non-200) and handled above this
/// mixin; we never turn a malformed 200 into that state.
mixin _NetworkBackendStackingOperations on NetworkBackendTransport {
  /// Push the host config to apply on the next start.
  Future<void> stackingUpdateConfig(LiveStackingConfig config) async {
    await _post(
      StackingApi.updateConfig,
      body: {'config': _stackingConfigToJson(config)},
    );
  }

  /// Liveness + counters.
  ///
  /// `active` must be a boolean and `frameCount` a non-negative integer. A
  /// missing/malformed value throws — a protocol failure must not read as a
  /// truthful-looking idle host (`active: false, frameCount: 0`).
  Future<({bool active, int frameCount})> stackingStatus() async {
    const endpoint = 'GET /api/stacking/status';
    final response = await _get(StackingApi.status);
    return (
      active: _requireStackingBool(response, 'active', endpoint),
      frameCount: _requireStackingInt(response, 'frameCount', endpoint, min: 0),
    );
  }
}

extension _NetworkBackendStackingOperationsHelpers on NetworkBackendTransport {
  Map<String, Object?> _stackingConfigToJson(LiveStackingConfig c) => {
    'sigmaClipEnabled': c.sigmaClipEnabled,
    'sigmaClipThreshold': c.sigmaClipThreshold,
    'maxMatchStars': c.maxMatchStars,
    'matchRadiusPx': c.matchRadiusPx,
    'matchFluxTolerance': c.matchFluxTolerance,
    'minMatchedPairs': c.minMatchedPairs,
    'sensorMode': c.sensorMode,
    if (c.bayerPattern != null) 'bayerPattern': c.bayerPattern,
    'demosaicQuality': c.demosaicQuality,
  };

  /// Require an integral [key] on [json] that is at least [min]. JSON numbers
  /// decode to `int` or `double`; a double is accepted only when it carries no
  /// fractional part (so a genuinely non-integral count like `1.5` is rejected,
  /// while a whole-valued `5.0` is honoured). Throws when absent, non-numeric,
  /// non-finite, non-integral, or below [min].
  int _requireStackingInt(
    Map<String, dynamic> json,
    String key,
    String endpoint, {
    required int min,
    int? max,
  }) {
    final value = json[key];
    if (value is int) {
      if (value < min) {
        throw FormatException(
          '$endpoint response field `$key` must be >= $min, got $value',
        );
      }
      if (max != null && value > max) {
        throw FormatException(
          '$endpoint response field `$key` must be <= $max, got $value',
        );
      }
      return value;
    }
    if (value is double) {
      if (!value.isFinite || value != value.roundToDouble()) {
        throw FormatException(
          '$endpoint response field `$key` must be an integer, got $value',
        );
      }
      final asInt = value.toInt();
      if (asInt < min) {
        throw FormatException(
          '$endpoint response field `$key` must be >= $min, got $asInt',
        );
      }
      if (max != null && asInt > max) {
        throw FormatException(
          '$endpoint response field `$key` must be <= $max, got $asInt',
        );
      }
      return asInt;
    }
    throw FormatException(
      '$endpoint response field `$key` must be an integer, got '
      '${value.runtimeType}',
    );
  }

  RemoteStackedResult _savedStackResultFromJson(
    Map<String, dynamic> json,
    String endpoint,
  ) {
    final id = _requireStackingInt(json, 'id', endpoint, min: 1);
    final width = _requireStackingInt(
      json,
      'width',
      endpoint,
      min: 1,
      max: 200000,
    );
    final height = _requireStackingInt(
      json,
      'height',
      endpoint,
      min: 1,
      max: 200000,
    );
    final framesStacked = _requireStackingInt(
      json,
      'framesStacked',
      endpoint,
      min: 0,
    );
    final framesAttempted = _requireStackingInt(
      json,
      'framesAttempted',
      endpoint,
      min: 0,
    );
    if (framesStacked > framesAttempted) {
      throw FormatException(
        '$endpoint response has framesStacked ($framesStacked) greater than '
        'framesAttempted ($framesAttempted)',
      );
    }
    final channels = _requireStackingChannels(json, endpoint);
    final isColor = _requireStackingBool(json, 'isColor', endpoint);
    if (isColor != (channels == 3)) {
      throw FormatException(
        '$endpoint response fields `isColor` and `channels` disagree',
      );
    }
    final createdAtRaw = json['createdAt'];
    final createdAt = createdAtRaw is String
        ? tryParseWireTime(createdAtRaw)
        : null;
    if (createdAt == null) {
      throw FormatException(
        '$endpoint response field `createdAt` must be an ISO-8601 timestamp',
      );
    }
    final previewAvailable = _requireStackingBool(
      json,
      'previewAvailable',
      endpoint,
    );
    final integrationSecs = _requireStackingNonNegativeDouble(
      json,
      'integrationSecs',
      endpoint,
    );
    final avgAlignmentResidual = _requireStackingNonNegativeDouble(
      json,
      'avgAlignmentResidual',
      endpoint,
    );

    return RemoteStackedResult(
      result: StackAndShareResult(
        id: id,
        sessionId: _optionalSavedStackId(json, 'sessionId', endpoint),
        targetId: _optionalSavedStackId(json, 'targetId', endpoint),
        targetName: _optionalSavedStackString(
          json,
          'targetName',
          endpoint,
          maxLength: 1024,
        ),
        width: width,
        height: height,
        framesStacked: framesStacked,
        framesAttempted: framesAttempted,
        integrationSecs: integrationSecs,
        avgAlignmentResidual: avgAlignmentResidual,
        avgHfr: _optionalSavedStackDouble(json, 'avgHfr', endpoint),
        filter: _optionalSavedStackString(
          json,
          'filter',
          endpoint,
          maxLength: 128,
        ),
        isColor: isColor,
        channels: channels,
        createdAt: createdAt,
        stats: LiveStackingStats(
          stackedFrameCount: framesStacked,
          totalFramesAttempted: framesAttempted,
          avgAlignmentResidual: avgAlignmentResidual,
        ),
      ),
      previewAvailable: previewAvailable,
    );
  }

  /// Require a nested object for [key] on [json]. Throws when absent or when the
  /// value is a non-object (list, scalar, null).
  Map<String, dynamic> _requireStackingObject(
    Map<String, dynamic> json,
    String key,
    String endpoint,
  ) {
    final value = json[key];
    if (value is! Map) {
      throw FormatException(
        '$endpoint response is missing required object `$key`',
      );
    }
    return Map<String, dynamic>.from(value);
  }

  /// Require and decode the stats object under `stats`. Counts must be
  /// integral and non-negative; averages must be finite and non-negative. Of
  /// the six counters and averages none is defaulted: a partial stats object
  /// throws. The filter fields are newer than the endpoint and optional.
  LiveStackingStats _requireStackingStats(
    Map<String, dynamic> json,
    String endpoint,
  ) {
    final stats = _requireStackingObject(json, 'stats', endpoint);
    return LiveStackingStats(
      stackedFrameCount: _requireStackingInt(
        stats,
        'stackedFrameCount',
        endpoint,
        min: 0,
      ),
      totalFramesAttempted: _requireStackingInt(
        stats,
        'totalFramesAttempted',
        endpoint,
        min: 0,
      ),
      rejectedAlignmentFailures: _requireStackingInt(
        stats,
        'rejectedAlignmentFailures',
        endpoint,
        min: 0,
      ),
      avgMatchedPairs: _requireStackingNonNegativeDouble(
        stats,
        'avgMatchedPairs',
        endpoint,
      ),
      avgAlignmentResidual: _requireStackingNonNegativeDouble(
        stats,
        'avgAlignmentResidual',
        endpoint,
      ),
      totalSigmaRejectedPixels: _requireStackingInt(
        stats,
        'totalSigmaRejectedPixels',
        endpoint,
        min: 0,
      ),
      // An unfiltered stack has no filter name.
      filter: _optionalFilterName(stats['filter']),
      otherFilterFrames: switch (stats['otherFilterFrames']) {
        final int count when count > 0 => count,
        _ => 0,
      },
      lastOtherFilter: _optionalFilterName(stats['lastOtherFilter']),
    );
  }

  /// Require the stacked result's `channels`, accepting only the two documented
  /// counts.
  ///
  /// `channels` REQUIRED (no absent→mono fallback): the remote stacking client
  /// ([stacking_operations.dart]) and the host handler that emits `channels`
  /// were introduced together in the same commit, so no released host ever
  /// returned a stacking result without it. A silent default of `1` would let a
  /// truncated RGB buffer (width*height*3 samples the client reads as mono) be
  /// displayed as a valid mono stack, so a missing/malformed `channels` throws.
  int _requireStackingChannels(Map<String, dynamic> json, String endpoint) {
    final channels = _requireStackingInt(json, 'channels', endpoint, min: 1);
    if (channels != 1 && channels != 3) {
      throw FormatException(
        '$endpoint response field `channels` must be 1 (mono) or 3 (RGB), '
        'got $channels',
      );
    }
    return channels;
  }

  /// Decode the raw preview buffer into little-endian u16 samples, validating
  /// that its size matches the declared [width] x [height] x [channels] stack
  /// exactly before reading a single pixel.
  Uint16List _decodeStackingPreview(
    Uint8List bytes,
    int width,
    int height,
    int channels,
    String endpoint,
  ) {
    final byteLength = bytes.lengthInBytes;
    // Each sample is a little-endian u16, so the buffer must be an even number
    // of bytes; an odd length means the payload was truncated mid-sample.
    if (byteLength.isOdd) {
      throw FormatException(
        '$endpoint returned an odd-length buffer ($byteLength bytes); '
        'little-endian u16 samples require an even byte count',
      );
    }
    final sampleCount = byteLength >> 1;
    // Overflow-safe exact-size validation. The buffer must hold exactly
    // width * height * channels samples, but forming that product directly
    // could overflow a 64-bit int if a hostile/buggy host declares absurd
    // dimensions — wrapping to a value that happens to equal the real length,
    // so a bogus buffer would pass. Instead we take the actually-allocated
    // sample count (bounded by the received buffer, hence a sane int) and
    // divide it down by each positive factor, demanding a remainder-free,
    // exact match at every step. That is arithmetically identical to
    // `sampleCount == width * height * channels` but cannot overflow, and it
    // rejects truncated, oversized, and dimension/channel-mismatched payloads
    // in a single pass. (`||` short-circuits so the later divisions only run
    // once the earlier remainder is known to be zero.)
    if (sampleCount % channels != 0 ||
        (sampleCount ~/ channels) % width != 0 ||
        (sampleCount ~/ channels) ~/ width != height) {
      throw FormatException(
        '$endpoint returned $byteLength bytes ($sampleCount u16 samples), '
        'which does not match the ${width}x${height}x$channels stack declared '
        'by GET /api/stacking/result',
      );
    }

    // Decode little-endian u16 samples. The host writes native (LE) order and
    // tags the response `x-stack-endian: little`.
    final byteData = ByteData.sublistView(bytes);
    final samples = Uint16List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      samples[i] = byteData.getUint16(i * 2, Endian.little);
    }
    return samples;
  }

  // Strict field decoders
  //
  // Each helper requires the field to be present with the correct type and
  // fails with a message naming the endpoint and field. Nothing is defaulted,
  // clamped, or coerced from a missing value: absent data is a protocol error.

  /// Require a boolean [key] on [json]. Throws when absent or non-boolean.
  bool _requireStackingBool(
    Map<String, dynamic> json,
    String key,
    String endpoint,
  ) {
    final value = json[key];
    if (value is! bool) {
      throw FormatException(
        '$endpoint response field `$key` must be a boolean, got '
        '${value.runtimeType}',
      );
    }
    return value;
  }

  /// Require a finite, non-negative number for [key] on [json]. Averages ride
  /// the wire as doubles; an `int` is tolerated (a whole-valued average) but a
  /// missing value, a NaN/Infinity, or a negative is a protocol error.
  double _requireStackingNonNegativeDouble(
    Map<String, dynamic> json,
    String key,
    String endpoint,
  ) {
    final value = json[key];
    if (value is! num) {
      throw FormatException(
        '$endpoint response field `$key` must be a number, got '
        '${value.runtimeType}',
      );
    }
    final asDouble = value.toDouble();
    if (!asDouble.isFinite || asDouble < 0) {
      throw FormatException(
        '$endpoint response field `$key` must be a finite, non-negative '
        'number, got $asDouble',
      );
    }
    return asDouble;
  }

  String? _optionalSavedStackString(
    Map<String, dynamic> json,
    String key,
    String endpoint, {
    required int maxLength,
  }) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String || value.length > maxLength) {
      throw FormatException(
        '$endpoint response field `$key` must be null or a string no longer '
        'than $maxLength characters',
      );
    }
    return value;
  }

  int? _optionalSavedStackId(
    Map<String, dynamic> json,
    String key,
    String endpoint,
  ) {
    if (json[key] == null) return null;
    return _requireStackingInt(json, key, endpoint, min: 1);
  }

  double? _optionalSavedStackDouble(
    Map<String, dynamic> json,
    String key,
    String endpoint,
  ) {
    if (json[key] == null) return null;
    return _requireStackingNonNegativeDouble(json, key, endpoint);
  }

  String? _optionalFilterName(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;
}
