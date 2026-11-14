import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// bridge-boundary: guiding_handlers
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

/// Handlers for the guiding endpoints. `/api/guider/*` drives the host's
/// guider, PHD2 or the built-in guider as its profile names; `/api/phd2/*` is
/// PHD2's connection and its own settings.
class GuidingHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    GuidingApi.phd2IsRunning: handlePhd2IsRunning,
    GuidingApi.phd2Probe: handlePhd2Probe,
    GuidingApi.phd2Connect: handlePhd2Connect,
    GuidingApi.phd2Disconnect: handlePhd2Disconnect,
    GuidingApi.phd2ClearCalibration: handlePhd2ClearCalibration,
    GuidingApi.phd2FlipCalibration: handlePhd2FlipCalibration,
    GuidingApi.phd2GetAlgoParamNames: handlePhd2GetAlgoParamNames,
    GuidingApi.phd2GetAlgoParam: handlePhd2GetAlgoParam,
    GuidingApi.phd2SetAlgoParam: handlePhd2SetAlgoParam,
    GuidingApi.guiderStartGuiding: handleGuiderStartGuiding,
    GuidingApi.guiderStopGuiding: handleGuiderStopGuiding,
    GuidingApi.guiderDither: handleGuiderDither,
    GuidingApi.guiderLoop: handleGuiderLoop,
    GuidingApi.guiderSetPaused: handleGuiderSetPaused,
    GuidingApi.guiderFindStar: handleGuiderFindStar,
    GuidingApi.guiderSetLockPosition: handleGuiderSetLockPosition,
    GuidingApi.guiderGetLockPosition: handleGuiderGetLockPosition,
    GuidingApi.guiderDeselectStar: handleGuiderDeselectStar,
    GuidingApi.guiderGetStarImage: handleGuiderGetStarImage,
    GuidingApi.guiderGetStatus: handleGuiderGetStatus,
    GuidingApi.guiderGetCalibration: handleGuiderGetCalibration,
    GuidingApi.builtinGuiderGetConfig: handleBuiltinGuiderGetConfig,
    GuidingApi.builtinGuiderSetConfig: handleBuiltinGuiderSetConfig,
  };

  final ProviderContainer container;
  Future<void>? _startDrain;
  bool _stopInFlight = false;

  GuidingHandlers(this.container);

  /// Upper bound for a guide-star crop edge (pixels). The built-in guider clamps
  /// the crop to the frame, but PHD2's `get_star_image` (min 15, default 32)
  /// and the returned width×height×2 byte buffer are driven by this
  /// value — so an unbounded `size` is a memory-abuse vector. 2048 comfortably
  /// exceeds any real guide-camera sensor edge while capping a single crop at
  /// ~8 MB of raw pixels.
  static const int _maxStarImageSize = 2048;

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'GuidingHandlers');

  /// Validate the `host`/`port` query pair shared by the PHD2 reachability
  /// endpoints.
  ///
  /// Fail closed on supplied-but-invalid values so a garbage port never gets
  /// silently probed as 4400 (masking the client's typo as a real result).
  /// Validate before the backend read so an invalid request does no work.
  ({String host, int port}) _phd2Endpoint(Request request) {
    final query = request.url.queryParameters;
    final hostParam = query['host'];
    final String host;
    if (hostParam == null) {
      host = 'localhost';
    } else if (hostParam.trim().isEmpty) {
      throw BadRequestError(
        field: 'host',
        expected: 'string',
        message: 'host must not be blank',
      );
    } else if (hostParam.trim().length > 253) {
      throw BadRequestError(
        field: 'host',
        expected: 'string',
        message: 'host exceeds maximum length of 253',
      );
    } else {
      host = hostParam.trim();
    }
    final port = optionalQueryInt(query, 'port', min: 1, max: 65535) ?? 4400;
    return (host: host, port: port);
  }

  Future<Response> handlePhd2IsRunning(Request request) async {
    // Probe whether a PHD2 event server is reachable. This runs on the host,
    // so the loopback PHD2 socket (or any host-reachable host:port) the
    // remote client can't touch directly is probed here on its behalf.
    final endpoint = _phd2Endpoint(request);

    final backend = container.read(guidingBackendProvider);
    final running = await backend.isPhd2Running(
      host: endpoint.host,
      port: endpoint.port,
    );

    return jsonOk({"running": running});
  }

  Future<Response> handlePhd2Probe(Request request) async {
    // Same host-side reasoning as handlePhd2IsRunning, but this one completes
    // PHD2's opening handshake so the answer names the version and profile
    // that replied instead of only asserting the port is held.
    final endpoint = _phd2Endpoint(request);

    final backend = container.read(guidingBackendProvider);
    final result = await backend.phd2Probe(
      host: endpoint.host,
      port: endpoint.port,
    );

    return jsonOk(result.toJson());
  }

  Future<Response> handlePhd2Connect(Request request) async {
    _logInfo('[API] POST /api/phd2/connect');
    final payload = await readJsonObject(request);
    final host = optionalString(payload, 'host', maxLength: 253) ?? 'localhost';
    final port = optionalInt(payload, 'port', min: 1, max: 65535) ?? 4400;
    // Route through DeviceService so the host auto-launches PHD2 when
    // configured, matching the desktop Equipment → Guider connect path.
    // Raw backend.phd2Connect skips _ensurePhd2Running on the desktop.
    final deviceService = container.read(deviceServiceProvider);
    await deviceService.connect(
      DeviceType.guider,
      kPhd2CanonicalId,
      host: host,
      port: port,
    );

    // Linked clients read GET /api/guider/status right after POST connect.
    // Block until PHD2 answers so we do not return success early.
    final backend = container.read(guidingBackendProvider);
    await pollPhd2Connected(backend);

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.guider,
      action: HostMutationAction.connected,
      entityId: 'phd2_guider',
      extra: {'name': 'PHD2'},
    );
    return jsonOk({"status": "connected"});
  }

  Future<Response> handlePhd2Disconnect(Request request) async {
    _logInfo('[API] POST /api/phd2/disconnect');
    final backend = container.read(guidingBackendProvider);
    final status = await readPhd2StatusOrDisconnected(backend);
    if (_startDrain != null ||
        (status.connected && status.state.toLowerCase() != 'stopped')) {
      await _runStop(backend.guiderStopGuiding);
    }
    final deviceService = container.read(deviceServiceProvider);
    try {
      await deviceService.disconnect(DeviceType.guider);
    } on DeviceNotConnectedException {
      await backend.phd2Disconnect();
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.guider,
      action: HostMutationAction.disconnected,
      entityId: 'phd2_guider',
    );
    return jsonOk({"status": "disconnected"});
  }

  Map<String, Object?> _statusJson(Phd2Status status) => {
    "deviceId": status.deviceId,
    "state": status.state,
    "connected": status.connected,
    "rmsRa": status.rmsRa,
    "rmsDec": status.rmsDec,
    "rmsTotal": status.rmsTotal,
    "snr": status.snr,
    "starMass": status.starMass,
    "avgDistance": status.avgDistance,
    // Guide camera arcsec/px; null when the guider has no scale.
    "pixelScale": status.pixelScale,
    // Per-star list from the built-in multi-star guider. Empty for PHD2 and
    // external guiders, which report one lock star.
    "trackedStars": [for (final s in status.trackedStars) s.toJson()],
    // Why the guider is stopped or held (autofocus, meridian_flip,
    // tracking_limit_hold, ...), so a planned stop never reads as lost
    // guiding to a watcher. Null while guiding runs.
    "stopReason": status.stopReason,
    "stopReasonText": guidingStopReasonText(status.stopReason),
  };

  Future<Response> handlePhd2ClearCalibration(Request request) async {
    _logInfo('[API] POST /api/phd2/clear-calibration');
    final payload = await readJsonObject(request);
    final which = optionalString(payload, 'which') ?? 'both';

    final backend = container.read(guidingBackendProvider);
    await backend.phd2ClearCalibration(which: which);

    return jsonOk({"status": "ok"});
  }

  Future<Response> handlePhd2FlipCalibration(Request request) async {
    _logInfo('[API] POST /api/phd2/flip-calibration');
    final backend = container.read(guidingBackendProvider);
    await backend.phd2FlipCalibration();

    return jsonOk({"status": "ok"});
  }

  Map<String, Object?> _calibrationJson(Phd2CalibrationData data) => {
    "isCalibrated": data.isCalibrated,
    "raAngle": data.rotationAngle,
    "raRate": data.raRate,
    "decRate": data.decRate,
  };

  static bool _isNoLockPosition(Object error) {
    if (error is bridge.SkotiqError) {
      return error.maybeMap(
        operationFailed: (failure) {
          final message = failure.field0.toLowerCase();
          return message.contains('get_lock_position') &&
              (message.contains('got null') ||
                  message.contains('missing or non-numeric'));
        },
        orElse: () => false,
      );
    }
    return false;
  }

  static bool _isNoStarSelected(Object error) {
    if (error is bridge.SkotiqError) {
      return error.maybeMap(
        operationFailed: (failure) =>
            failure.field0.toLowerCase().contains('no star selected'),
        orElse: () => false,
      );
    }
    return false;
  }

  Future<Response> handlePhd2GetAlgoParamNames(Request request) async {
    final axis = request.url.queryParameters['axis'];
    if (axis == null || (axis != 'ra' && axis != 'dec')) {
      throw BadRequestError(
        field: 'axis',
        expected: "'ra' or 'dec'",
        message: "Missing or invalid 'axis' query parameter",
      );
    }

    final backend = container.read(guidingBackendProvider);
    final names = await backend.phd2GetAlgoParamNames(axis: axis);

    return jsonOk({"axis": axis, "names": names});
  }

  Future<Response> handlePhd2GetAlgoParam(Request request) async {
    final axis = request.url.queryParameters['axis'];
    final name = request.url.queryParameters['name'];

    if (axis == null || (axis != 'ra' && axis != 'dec')) {
      throw BadRequestError(
        field: 'axis',
        expected: "'ra' or 'dec'",
        message: "Missing or invalid 'axis' query parameter",
      );
    }

    if (name == null || name.isEmpty) {
      throw BadRequestError(
        field: 'name',
        expected: 'string',
        message: "Missing 'name' query parameter",
      );
    }

    final backend = container.read(guidingBackendProvider);
    final value = await backend.phd2GetAlgoParam(axis: axis, name: name);

    return jsonOk({"axis": axis, "name": name, "value": value});
  }

  Future<Response> handlePhd2SetAlgoParam(Request request) async {
    _logInfo('[API] POST /api/phd2/algo-param');
    final payload = await readJsonObject(request);
    final axis = requireString(payload, 'axis');
    if (axis != 'ra' && axis != 'dec') {
      throw BadRequestError(field: 'axis', expected: "'ra' or 'dec'");
    }
    final name = requireString(payload, 'name');
    final value = requireDouble(payload, 'value');

    final backend = container.read(guidingBackendProvider);
    await backend.phd2SetAlgoParam(axis: axis, name: name, value: value);

    return jsonOk({"status": "ok", "axis": axis, "name": name, "value": value});
  }

  Future<Response> handleGuiderStartGuiding(Request request) async {
    _logInfo('[API] POST /api/guider/start-guiding');
    final payload = await readJsonObject(request);
    final settle = _readSettle(payload);

    final backend = container.read(guidingBackendProvider);
    await _runStart(
      () => backend.guiderStartGuiding(
        settlePixels: settle.pixels,
        settleTime: settle.time,
        settleTimeout: settle.timeout,
      ),
    );

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.guider,
      action: HostMutationAction.started,
      extra: {'state': 'guiding'},
    );
    return jsonOk({"status": "guiding"});
  }

  Future<Response> handleGuiderStopGuiding(Request request) async {
    _logInfo('[API] POST /api/guider/stop-guiding');
    final backend = container.read(guidingBackendProvider);
    await _runStop(backend.guiderStopGuiding);

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.guider,
      action: HostMutationAction.stopped,
      extra: {'state': 'stopped'},
    );
    return jsonOk({"status": "stopped"});
  }

  Future<Response> handleGuiderDither(Request request) async {
    _logInfo('[API] POST /api/guider/dither');
    final payload = await readJsonObject(request);
    final amount = optionalDouble(payload, 'amount') ?? 5.0;
    if (!amount.isFinite || amount < 0.1 || amount > 100) {
      throw BadRequestError(
        field: 'amount',
        expected: 'finite number from 0.1 to 100',
      );
    }
    final settle = _readSettle(payload);

    final backend = container.read(guidingBackendProvider);
    await backend.guiderDither(
      amount: amount,
      raOnly: optionalBool(payload, 'raOnly') ?? false,
      settlePixels: settle.pixels,
      settleTime: settle.time,
      settleTimeout: settle.timeout,
    );

    return jsonOk({"status": "dithering"});
  }

  Future<Response> handleGuiderLoop(Request request) async {
    _logInfo('[API] POST /api/guider/loop');
    final backend = container.read(guidingBackendProvider);
    await backend.guiderLoop();

    return jsonOk({"status": "looping"});
  }

  Future<Response> handleGuiderSetPaused(Request request) async {
    _logInfo('[API] POST /api/guider/pause');
    final payload = await readJsonObject(request);
    final paused = requireBool(payload, 'paused');

    final backend = container.read(guidingBackendProvider);
    await backend.guiderSetPaused(paused);

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.guider,
      action: paused ? HostMutationAction.paused : HostMutationAction.resumed,
      extra: {'paused': paused},
    );
    return jsonOk({"status": "ok"});
  }

  Future<Response> handleGuiderFindStar(Request request) async {
    _logInfo('[API] POST /api/guider/find-star');
    final backend = container.read(guidingBackendProvider);
    final double x;
    final double y;
    try {
      (x, y) = await backend.guiderFindStar();
    } catch (error, stackTrace) {
      // "No guide star found" is an ordinary outcome — a sparse field, clouds,
      // or a defocused frame — not a server fault. The native layer raises it as
      // an unstructured `OperationFailed`, which the error translator maps to
      // `500 internal_error` (observed live against the built-in guider). A 500
      // tells a remote client the HOST broke and invites a retry storm, so
      // answer 404 with a code the caller can branch on.
      //
      // Classify off the typed bridge variant first (same shape as the
      // exposure-cancelled check in camera_handlers): builtin_guider raises
      // `OperationFailed("No guide star found")` and the PHD2 path raises
      // `OperationFailed("Failed to find star: <phd2 text>")`. The stringified
      // fallback only covers a chained network backend, which re-raises the
      // host's message without the bridge type. Neither value is ever placed in
      // a response body — it selects the status code and nothing more.
      const marker = 'no guide star found';
      final isNoStarFound =
          (error is bridge.SkotiqError &&
              error.maybeMap(
                operationFailed: (failure) =>
                    failure.field0.toLowerCase().contains(marker),
                orElse: () => false,
              )) ||
          error.toString().toLowerCase().contains(marker);
      if (isNoStarFound) {
        throw HandlerFailure(
          code: 'guide_star_not_found',
          message:
              'No guide star found in the current frame. Check focus, '
              'exposure length, and that the guide camera is on sky.',
          statusCode: 404,
          cause: error,
          stackTrace: stackTrace,
        );
      }
      rethrow;
    }

    return jsonOk({"x": x, "y": y});
  }

  Future<Response> handleGuiderSetLockPosition(Request request) async {
    _logInfo('[API] POST /api/guider/set-lock-position');
    final payload = await readJsonObject(request);
    final x = requireDouble(payload, 'x');
    final y = requireDouble(payload, 'y');

    final backend = container.read(guidingBackendProvider);
    await backend.guiderSetLockPosition(
      x: x,
      y: y,
      exact: optionalBool(payload, 'exact') ?? false,
    );

    return jsonOk({"status": "ok", "x": x, "y": y});
  }

  Future<Response> handleGuiderGetStatus(Request request) async {
    final backend = container.read(guidingBackendProvider);
    try {
      return jsonOk(_statusJson(await backend.guiderGetStatus()));
    } catch (e) {
      // A watcher polls this whether or not the host has a guider: no guider
      // answering reads as a disconnected guider, not a server failure.
      _logger.debug('Guider status unavailable: $e', source: 'GuidingHandlers');
      return jsonOk(_statusJson(kPhd2DisconnectedStatus));
    }
  }

  Future<Response> handleGuiderGetCalibration(Request request) async {
    final backend = container.read(guidingBackendProvider);
    final data = await backend.guiderGetCalibration();
    return jsonOk(_calibrationJson(data));
  }

  Future<Response> handleGuiderGetLockPosition(Request request) async {
    final backend = container.read(guidingBackendProvider);
    try {
      final (x, y) = await backend.guiderGetLockPosition();
      return jsonOk({"x": x, "y": y});
    } catch (error) {
      if (_isNoLockPosition(error)) {
        return jsonError(
          code: 'no_lock_position',
          message: 'The guider has no guide-star lock position.',
          statusCode: 409,
        );
      }
      rethrow;
    }
  }

  Future<Response> handleGuiderDeselectStar(Request request) async {
    _logInfo('[API] POST /api/guider/deselect-star');
    final backend = container.read(guidingBackendProvider);
    await backend.guiderDeselectStar();
    return jsonOk({"status": "ok"});
  }

  Future<Response> handleGuiderGetStarImage(Request request) async {
    // Absent → the 50 px default thumbnail. A supplied value must be a positive
    // whole integer bounded by [_maxStarImageSize]; validate before the backend
    // read so a malformed size does no work and never reaches the guider.
    final size =
        optionalQueryInt(
          request.url.queryParameters,
          'size',
          min: 1,
          max: _maxStarImageSize,
        ) ??
        50;

    final backend = container.read(guidingBackendProvider);
    final Phd2StarImage image;
    try {
      image = await backend.guiderGetStarImage(size: size);
    } catch (error) {
      // Looping with no star selected is a normal state, not a server failure.
      if (_isNoStarSelected(error)) {
        return jsonError(
          code: 'no_star_selected',
          message: 'The guider has no guide star selected.',
          statusCode: 409,
        );
      }
      rethrow;
    }

    return jsonOk({
      "frame": image.frame,
      "width": image.width,
      "height": image.height,
      "starX": image.starX,
      "starY": image.starY,
      "pixels": base64Encode(image.pixels),
    });
  }

  Future<Response> handleBuiltinGuiderGetConfig(Request request) async {
    final backend = container.read(guidingBackendProvider);
    final config = await backend.builtinGuiderGetConfig();
    return jsonOk(config.toJson());
  }

  Future<Response> handleBuiltinGuiderSetConfig(Request request) async {
    _logInfo('[API] POST /api/builtin-guider/config');
    final payload = await readJsonObject(request);
    final backend = container.read(guidingBackendProvider);
    await backend.builtinGuiderSetConfig(BuiltinGuiderConfig.fromJson(payload));
    return jsonOk({"status": "ok"});
  }

  ({double pixels, double time, double timeout}) _readSettle(
    Map<String, dynamic> payload,
  ) {
    final pixels = optionalDouble(payload, 'settlePixels') ?? 1.0;
    final time = optionalDouble(payload, 'settleTime') ?? 10.0;
    final requestedTimeout = optionalDouble(payload, 'settleTimeout') ?? 60.0;
    if (!pixels.isFinite || pixels < 0.05 || pixels > 20) {
      throw BadRequestError(
        field: 'settlePixels',
        expected: 'finite number from 0.05 to 20',
      );
    }
    if (!time.isFinite || time < 0 || time > 120) {
      throw BadRequestError(
        field: 'settleTime',
        expected: 'finite number from 0 to 120',
      );
    }
    if (!requestedTimeout.isFinite ||
        requestedTimeout < 1 ||
        requestedTimeout > 600) {
      throw BadRequestError(
        field: 'settleTimeout',
        expected: 'finite number from 1 to 600',
      );
    }
    return (
      pixels: pixels,
      time: time,
      timeout: requestedTimeout < time + 1 ? time + 1 : requestedTimeout,
    );
  }

  /// One start or stop of guiding at a time; a stop always waits out a
  /// start in progress and stops again after it.
  Future<void> _runStart(Future<void> Function() start) async {
    if (_startDrain != null || _stopInFlight) {
      throw HandlerFailure(
        code: 'guiding_command_busy',
        message: 'Another guiding start or stop is already in progress.',
        statusCode: 409,
      );
    }
    final operation = Future<void>.sync(start);
    final drain = operation.then<void>((_) {}, onError: (_, __) {});
    _startDrain = drain;
    try {
      await operation;
    } finally {
      if (identical(_startDrain, drain)) _startDrain = null;
    }
  }

  Future<void> _runStop(Future<void> Function() stop) async {
    if (_stopInFlight) {
      throw HandlerFailure(
        code: 'guiding_command_busy',
        message: 'A guiding stop is already in progress.',
        statusCode: 409,
      );
    }
    _stopInFlight = true;
    try {
      final start = _startDrain;
      await stop();
      if (start != null) {
        await start;
        await stop();
      }
    } finally {
      _stopInFlight = false;
    }
  }
}
