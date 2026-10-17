part of '../network_backend.dart';

mixin _NetworkBackendGuidingOperations on _NetworkBackendTransport {
  // PHD2 Guiding

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

  @override
  Future<void> phd2StartGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await _post('phd2/start-guiding', {
      'settlePixels': settlePixels,
      'settleTime': settleTime,
      'settleTimeout': settleTimeout,
    });
  }

  @override
  Future<void> phd2StopGuiding() async {
    await _post('phd2/stop-guiding');
  }

  @override
  Future<void> phd2Dither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await _post('phd2/dither', {
      'amount': amount,
      'raOnly': raOnly,
      'settlePixels': settlePixels,
      'settleTime': settleTime,
      'settleTimeout': settleTimeout,
    });
  }

  @override
  Future<Phd2Status> phd2GetStatus() async {
    final response = await _get('phd2/status');
    return Phd2Status(
      state: _requiredGuidingString(response, 'state', 'phd2/status'),
      connected: _requiredGuidingBool(response, 'connected', 'phd2/status'),
      rmsRa: _requiredGuidingDouble(response, 'rmsRa', 'phd2/status'),
      rmsDec: _requiredGuidingDouble(response, 'rmsDec', 'phd2/status'),
      rmsTotal: _requiredGuidingDouble(response, 'rmsTotal', 'phd2/status'),
      snr: _requiredGuidingDouble(response, 'snr', 'phd2/status'),
      starMass: _requiredGuidingDouble(response, 'starMass', 'phd2/status'),
      avgDistance: _requiredGuidingDouble(
        response,
        'avgDistance',
        'phd2/status',
      ),
      // Per-star list from the built-in multi-star guider (empty for PHD2).
      // Rides through the status JSON as a `trackedStars` array — no FRB regen.
      // This field was added after the original status route, so its absence on
      // an older host is the one supported compatibility case.
      trackedStars: _networkTrackedStars(response),
    );
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
        'GET /api/phd2/status returned a non-list `trackedStars` field',
      );
    }

    final stars = <GuideStar>[];
    for (final value in raw) {
      if (value is! Map) {
        throw const FormatException(
          'GET /api/phd2/status returned a non-object tracked star',
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
          'GET /api/phd2/status returned a malformed tracked star',
        );
      }
      stars.add(GuideStar.fromJson(star));
    }
    return stars;
  }

  /// Decode a star-image JSON envelope (shared by the PHD2 and built-in
  /// guider star-image routes, which return the same shape). `base64Decode`
  /// already yields a `Uint8List`, so no extra copy is needed.
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
  Future<Phd2StarImage> phd2GetStarImage({int size = 50}) async {
    final response = await _get('phd2/star-image', {'size': size});
    return _starImageFromJson(response);
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
  Future<void> phd2SetPaused(bool paused) async {
    await _post('phd2/pause', {'paused': paused});
  }

  @override
  Future<void> phd2ClearCalibration({String which = 'both'}) async {
    await _post('phd2/clear-calibration', {'which': which});
  }

  @override
  Future<void> phd2FlipCalibration() async {
    await _post('phd2/flip-calibration', {});
  }

  @override
  Future<Phd2CalibrationData> phd2GetCalibrationData() async {
    final response = await _post('phd2/get-calibration-data', {});
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
  Future<(double, double)> phd2FindStar() async {
    final response = await _post('phd2/find-star', {});
    return (
      (response['x'] as num).toDouble(),
      (response['y'] as num).toDouble(),
    );
  }

  @override
  Future<void> phd2SetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  }) async {
    await _post('phd2/set-lock-position', {'x': x, 'y': y, 'exact': exact});
  }

  @override
  Future<(double, double)> phd2GetLockPosition() async {
    final response = await _get('phd2/lock-position');
    return (
      (response['x'] as num).toDouble(),
      (response['y'] as num).toDouble(),
    );
  }

  @override
  Future<void> phd2Loop() async {
    await _post('phd2/loop', {});
  }

  @override
  Future<void> phd2DeselectStar() async {
    await _post('phd2/deselect-star', {});
  }

  // Generic Guiding (driver-agnostic abstraction)

  @override
  Future<void> guiderStartGuiding({
    required String deviceId,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await _post('guider/start-guiding', {
      'deviceId': deviceId,
      'settlePixels': settlePixels,
      'settleTime': settleTime,
      'settleTimeout': settleTimeout,
    });
  }

  @override
  Future<void> guiderStopGuiding({required String deviceId}) async {
    await _post('guider/stop-guiding', {'deviceId': deviceId});
  }

  @override
  Future<void> guiderDither({
    required String deviceId,
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    await _post('guider/dither', {
      'deviceId': deviceId,
      'amount': amount,
      'raOnly': raOnly,
      'settlePixels': settlePixels,
      'settleTime': settleTime,
      'settleTimeout': settleTimeout,
    });
  }

  @override
  Future<void> guiderLoop({required String deviceId}) async {
    await _post('guider/loop', {'deviceId': deviceId});
  }

  @override
  Future<(double, double)> guiderFindStar({required String deviceId}) async {
    final response = await _post('guider/find-star', {'deviceId': deviceId});
    return (
      (response['x'] as num).toDouble(),
      (response['y'] as num).toDouble(),
    );
  }

  @override
  Future<void> guiderSetLockPosition({
    required String deviceId,
    required double x,
    required double y,
    bool exact = false,
  }) async {
    await _post('guider/set-lock-position', {
      'deviceId': deviceId,
      'x': x,
      'y': y,
      'exact': exact,
    });
  }

  @override
  Future<(double, double)> guiderGetLockPosition({
    required String deviceId,
  }) async {
    final response = await _get(
      'guider/lock-position?deviceId=${Uri.encodeQueryComponent(deviceId)}',
    );
    return (
      (response['x'] as num).toDouble(),
      (response['y'] as num).toDouble(),
    );
  }

  @override
  Future<void> guiderDeselectStar({required String deviceId}) async {
    await _post('guider/deselect-star', {'deviceId': deviceId});
  }

  @override
  Future<Phd2StarImage> guiderGetStarImage({
    required String deviceId,
    int size = 50,
  }) async {
    final response = await _get(
      'guider/star-image?deviceId=${Uri.encodeQueryComponent(deviceId)}&size=$size',
    );
    return _starImageFromJson(response);
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
