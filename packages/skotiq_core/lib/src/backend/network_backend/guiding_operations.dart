part of '../network_backend.dart';

mixin _NetworkBackendGuidingOperations on _NetworkBackendTransport {
  @override
  Future<bool> isPhd2Running({
    String host = 'localhost',
    int port = 4400,
  }) async {
    // The PHD2 event-server socket lives on the host's loopback, which a
    // remote client cannot reach directly. Instead, ask the master to run
    // the probe on our behalf via GET /api/phd2/running. Older masters that
    // predate this endpoint return 404 — degrade to "not detected" so the
    // onboarding test-connection button shows a clean result instead of a
    // red exception.
    try {
      final response = await _get('phd2/running', {'host': host, 'port': port});
      final running = response['running'];
      if (running is! bool) {
        throw const FormatException(
          'GET /api/phd2/running returned no boolean `running` field',
        );
      }
      return running;
    } on ServerError catch (e) {
      if (e.httpStatus == 404) return false;
      rethrow;
    }
  }

  @override
  Future<Phd2ProbeResult> phd2Probe({
    String host = 'localhost',
    int port = 4400,
  }) async {
    try {
      final response = await _get('phd2/probe', {'host': host, 'port': port});
      return Phd2ProbeResult.fromJson(response);
    } on ServerError catch (e) {
      if (e.httpStatus != 404) rethrow;
      // A master that predates GET /api/phd2/probe can still answer the port
      // question. Report that as "reachable, version unknown" rather than
      // inventing an identification that endpoint never makes.
      final running = await isPhd2Running(host: host, port: port);
      return Phd2ProbeResult(
        outcome: running
            ? Phd2ProbeOutcome.reachableUnverified
            : Phd2ProbeOutcome.unreachable,
        error: running
            ? null
            : 'The imaging host reported nothing listening on $host:$port.',
      );
    }
  }

  @override
  Future<void> phd2Connect({String host = 'localhost', int port = 4400}) async {
    await _post('phd2/connect', {'host': host, 'port': port});
  }

  @override
  Future<void> phd2Disconnect() async {
    await _post('phd2/disconnect');
  }

  String _requiredGuidingString(
    Map<String, dynamic> response,
    String key,
    String endpoint,
  ) {
    final value = response[key];
    if (value is! String) {
      throw FormatException(
        'GET /api/$endpoint returned no string `$key` field',
      );
    }
    return value;
  }

  bool _requiredGuidingBool(
    Map<String, dynamic> response,
    String key,
    String endpoint,
  ) {
    final value = response[key];
    if (value is! bool) {
      throw FormatException(
        'GET /api/$endpoint returned no boolean `$key` field',
      );
    }
    return value;
  }

  double _requiredGuidingDouble(
    Map<String, dynamic> response,
    String key,
    String endpoint,
  ) {
    final value = response[key];
    if (value is! num) {
      throw FormatException(
        'GET /api/$endpoint returned no numeric `$key` field',
      );
    }
    return value.toDouble();
  }

  List<GuideStar> _networkTrackedStars(Map<String, dynamic> response) {
    if (!response.containsKey('trackedStars')) return const [];
    final raw = response['trackedStars'];
    if (raw is! List) {
      throw const FormatException(
        'GET /api/guider/status returned a non-list `trackedStars` field',
      );
    }

    final stars = <GuideStar>[];
    for (final value in raw) {
      if (value is! Map) {
        throw const FormatException(
          'GET /api/guider/status returned a non-object tracked star',
        );
      }
      final star = Map<String, dynamic>.from(value);
      final isLock = star.containsKey('is_lock')
          ? star['is_lock']
          : star['isLock'];
      if (star['id'] is! num ||
          star['x'] is! num ||
          star['y'] is! num ||
          star['flux'] is! num ||
          star['snr'] is! num ||
          isLock is! bool ||
          (star['residual'] != null && star['residual'] is! num) ||
          star['weight'] is! num) {
        throw const FormatException(
          'GET /api/guider/status returned a malformed tracked star',
        );
      }
      stars.add(GuideStar.fromJson(star));
    }
    return stars;
  }

  /// Decode a star-image JSON envelope. `base64Decode` already yields a
  /// `Uint8List`, so no extra copy is needed.
  Phd2StarImage _starImageFromJson(Map<String, dynamic> response) {
    return Phd2StarImage(
      frame: response['frame'] as int,
      width: response['width'] as int,
      height: response['height'] as int,
      starX: (response['starX'] as num).toDouble(),
      starY: (response['starY'] as num).toDouble(),
      pixels: base64Decode(response['pixels'] as String),
    );
  }

  @override
  Future<List<String>> phd2GetAlgoParamNames({required String axis}) async {
    final response = await _get('phd2/algo-params', {'axis': axis});
    // The server (handlePhd2GetAlgoParamNames) emits the list under the key
    // 'names' (alongside 'axis'); decoding 'params' here always yielded null and
    // threw on cast. Match the actual response envelope so the names decode.
    final names = response['names'] as List<dynamic>;
    return names.map((e) => e as String).toList();
  }

  @override
  Future<double> phd2GetAlgoParam({
    required String axis,
    required String name,
  }) async {
    final response = await _get('phd2/algo-param', {
      'axis': axis,
      'name': name,
    });
    return (response['value'] as num).toDouble();
  }

  @override
  Future<void> phd2SetAlgoParam({
    required String axis,
    required String name,
    required double value,
  }) async {
    await _post('phd2/algo-param', {
      'axis': axis,
      'name': name,
      'value': value,
    });
  }

  @override
  Future<void> phd2ClearCalibration({String which = 'both'}) async {
    await _post('phd2/clear-calibration', {'which': which});
  }

  @override
  Future<void> phd2FlipCalibration() async {
    await _post('phd2/flip-calibration', {});
  }

  Phd2CalibrationData _calibrationFromJson(Map<String, dynamic> response) {
    final isCalibrated = response['isCalibrated'] as bool;
    return Phd2CalibrationData(
      isCalibrated: isCalibrated,
      rotationAngle: (response['raAngle'] as num?)?.toDouble(),
      raRate: (response['raRate'] as num?)?.toDouble(),
      decRate: (response['decRate'] as num?)?.toDouble(),
      calibratedAt: isCalibrated ? DateTime.now() : null,
    );
  }

  @override
  Future<void> guiderStartGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await _post('guider/start-guiding', {
      'settlePixels': settlePixels,
      'settleTime': settleTime,
      'settleTimeout': settleTimeout,
    });
  }

  @override
  Future<void> guiderStopGuiding() async {
    await _post('guider/stop-guiding', {});
  }

  @override
  Future<void> guiderDither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await _post('guider/dither', {
      'amount': amount,
      'raOnly': raOnly,
      'settlePixels': settlePixels,
      'settleTime': settleTime,
      'settleTimeout': settleTimeout,
    });
  }

  @override
  Future<void> guiderLoop() async {
    await _post('guider/loop', {});
  }

  @override
  Future<void> guiderSetPaused(bool paused) async {
    await _post('guider/pause', {'paused': paused});
  }

  @override
  Future<(double, double)> guiderFindStar() async {
    final response = await _post('guider/find-star', {});
    return (
      (response['x'] as num).toDouble(),
      (response['y'] as num).toDouble(),
    );
  }

  @override
  Future<void> guiderSetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  }) async {
    await _post('guider/set-lock-position', {'x': x, 'y': y, 'exact': exact});
  }

  @override
  Future<(double, double)> guiderGetLockPosition() async {
    final response = await _get('guider/lock-position');
    return (
      (response['x'] as num).toDouble(),
      (response['y'] as num).toDouble(),
    );
  }

  @override
  Future<void> guiderDeselectStar() async {
    await _post('guider/deselect-star', {});
  }

  @override
  Future<Phd2StarImage> guiderGetStarImage({int size = 50}) async {
    final response = await _get('guider/star-image', {'size': size});
    return _starImageFromJson(response);
  }

  @override
  Future<Phd2Status> guiderGetStatus() async {
    const endpoint = 'guider/status';
    final response = await _get(endpoint);
    return Phd2Status(
      deviceId: response['deviceId'] as String?,
      state: _requiredGuidingString(response, 'state', endpoint),
      connected: _requiredGuidingBool(response, 'connected', endpoint),
      rmsRa: _requiredGuidingDouble(response, 'rmsRa', endpoint),
      rmsDec: _requiredGuidingDouble(response, 'rmsDec', endpoint),
      rmsTotal: _requiredGuidingDouble(response, 'rmsTotal', endpoint),
      snr: _requiredGuidingDouble(response, 'snr', endpoint),
      starMass: _requiredGuidingDouble(response, 'starMass', endpoint),
      avgDistance: _requiredGuidingDouble(response, 'avgDistance', endpoint),
      pixelScale: _positiveScale(response['pixelScale']),
      trackedStars: _networkTrackedStars(response),
      stopReason: response['stopReason'] as String?,
    );
  }

  double? _positiveScale(Object? value) {
    if (value is! num) return null;
    final scale = value.toDouble();
    return scale.isFinite && scale > 0 ? scale : null;
  }

  @override
  Future<Phd2CalibrationData> guiderGetCalibration() async {
    final response = await _get('guider/calibration');
    return _calibrationFromJson(response);
  }

  @override
  Future<BuiltinGuiderConfig> builtinGuiderGetConfig() async {
    final response = await _get('builtin-guider/config');
    return BuiltinGuiderConfig.fromJson(response);
  }

  @override
  Future<void> builtinGuiderSetConfig(BuiltinGuiderConfig config) async {
    await _post('builtin-guider/config', config.toJson());
  }
}
