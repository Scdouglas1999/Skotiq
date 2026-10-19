import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for PHD2 guiding endpoints
class GuidingHandlers {
  final ProviderContainer container;
  Future<void>? _phd2StartDrain;
  bool _phd2StopInFlight = false;

  GuidingHandlers(this.container);

  /// Upper bound for a guide-star crop edge (pixels). The built-in guider clamps
  /// the crop to the frame, but the PHD2 RPC path (`get_star_image`, min 15 /
  /// default 32) and the returned width×height×2 byte buffer are driven by this
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
    await deviceService.connectGuider(kPhd2CanonicalId, host: host, port: port);

    // Mobile companions verify GET /api/phd2/status immediately after POST
    // connect. Block until PHD2 RPC is live so we do not return success early.
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
    if (_phd2StartDrain != null ||
        (status.connected && status.state.toLowerCase() != 'stopped')) {
      await _runPhd2Stop(backend.phd2StopGuiding);
    }
    final deviceService = container.read(deviceServiceProvider);
    try {
      await deviceService.disconnectGuider();
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

  Future<Response> handlePhd2StartGuiding(Request request) async {
    _logInfo('[API] POST /api/phd2/start-guiding');
    final payload = await readJsonObject(request);
    final settle = _readSettle(payload);

    final backend = container.read(guidingBackendProvider);
    await _runPhd2Start(
      () => backend.phd2StartGuiding(
        settlePixels: settle.pixels,
        settleTime: settle.time,
        settleTimeout: settle.timeout,
      ),
    );

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.guider,
      action: HostMutationAction.started,
      entityId: 'phd2_guider',
      extra: {'state': 'guiding'},
    );
    return jsonOk({"status": "guiding"});
  }

  Future<Response> handlePhd2StopGuiding(Request request) async {
    _logInfo('[API] POST /api/phd2/stop-guiding');
    final backend = container.read(guidingBackendProvider);
    await _runPhd2Stop(backend.phd2StopGuiding);

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.guider,
      action: HostMutationAction.stopped,
      entityId: 'phd2_guider',
      extra: {'state': 'stopped'},
    );
    return jsonOk({"status": "stopped"});
  }

  Future<Response> handlePhd2Dither(Request request) async {
    _logInfo('[API] POST /api/phd2/dither');
    final payload = await readJsonObject(request);
    final amount = optionalDouble(payload, 'amount') ?? 5.0;
    if (!amount.isFinite || amount < 0.1 || amount > 100) {
      throw BadRequestError(
        field: 'amount',
        expected: 'finite number from 0.1 to 100',
      );
    }
    final raOnly = optionalBool(payload, 'raOnly') ?? false;
    final settle = _readSettle(payload);

    final backend = container.read(guidingBackendProvider);
    await backend.phd2Dither(
      amount: amount,
      raOnly: raOnly,
      settlePixels: settle.pixels,
      settleTime: settle.time,
      settleTimeout: settle.timeout,
    );

    return jsonOk({"status": "dithering"});
  }

  Future<Response> handlePhd2GetStatus(Request request) async {
    final backend = container.read(guidingBackendProvider);
    final status = await readPhd2StatusOrDisconnected(backend);

    return jsonOk({
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
      // Per-star list from the built-in multi-star guider, so the mobile/web
      // guider UI can render a real star list instead of an empty panel. Empty
      // for PHD2/external guiders (single aggregate lock star only).
      "trackedStars": [for (final s in status.trackedStars) s.toJson()],
    });
  }

  Future<Response> handlePhd2SetPaused(Request request) async {
    _logInfo('[API] POST /api/phd2/pause');
    final payload = await readJsonObject(request);
    final paused = requireBool(payload, 'paused');

    final backend = container.read(guidingBackendProvider);
    await backend.phd2SetPaused(paused);

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.guider,
      action: paused ? HostMutationAction.paused : HostMutationAction.resumed,
      entityId: 'phd2_guider',
      extra: {'paused': paused},
    );
    return jsonOk({"status": "ok"});
  }

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

  Future<Response> handlePhd2GetCalibrationData(Request request) async {
    _logInfo('[API] POST /api/phd2/get-calibration-data');
    final backend = container.read(guidingBackendProvider);
    final data = await backend.phd2GetCalibrationData();

    return jsonOk({
      "isCalibrated": data.isCalibrated,
      "raAngle": data.rotationAngle,
      "raRate": data.raRate,
      "decRate": data.decRate,
    });
  }

  Future<Response> handlePhd2FindStar(Request request) async {
    _logInfo('[API] POST /api/phd2/find-star');
    final backend = container.read(guidingBackendProvider);
    final (x, y) = await backend.phd2FindStar();

    return jsonOk({"x": x, "y": y});
  }

  Future<Response> handlePhd2SetLockPosition(Request request) async {
    _logInfo('[API] POST /api/phd2/set-lock-position');
    final payload = await readJsonObject(request);
    final x = requireDouble(payload, 'x');
    final y = requireDouble(payload, 'y');
    final exact = optionalBool(payload, 'exact') ?? false;

    final backend = container.read(guidingBackendProvider);
    await backend.phd2SetLockPosition(x: x, y: y, exact: exact);

    return jsonOk({"status": "ok"});
  }

  Future<Response> handlePhd2GetLockPosition(Request request) async {
    final backend = container.read(guidingBackendProvider);
    try {
      final (x, y) = await backend.phd2GetLockPosition();

      return jsonOk({"x": x, "y": y});
    } catch (error) {
      if (_isPhd2NoLockPosition(error)) {
        return jsonError(
          code: 'no_lock_position',
          message: 'PHD2 has no guide-star lock position.',
          statusCode: 409,
        );
      }
      rethrow;
    }
  }

  Future<Response> handlePhd2Loop(Request request) async {
    _logInfo('[API] POST /api/phd2/loop');
    final backend = container.read(guidingBackendProvider);
    await backend.phd2Loop();

    return jsonOk({"status": "ok"});
  }

  Future<Response> handlePhd2DeselectStar(Request request) async {
    _logInfo('[API] POST /api/phd2/deselect-star');
    final backend = container.read(guidingBackendProvider);
    await backend.phd2DeselectStar();

    return jsonOk({"status": "ok"});
  }

  Future<Response> handlePhd2GetStarImage(Request request) async {
    // Absent → the 50 px default thumbnail. A supplied value must be a positive
    // whole integer bounded by [_maxStarImageSize]; validate before the backend
    // read so a malformed size does no work and never reaches the RPC.
    final size =
        optionalQueryInt(
          request.url.queryParameters,
          'size',
          min: 1,
          max: _maxStarImageSize,
        ) ??
        50;

    final backend = container.read(guidingBackendProvider);
    final Phd2StarImage starImage;
    try {
      starImage = await backend.phd2GetStarImage(size: size);
    } catch (error) {
      if (_isPhd2NoStarSelected(error)) {
        return jsonError(
          code: 'no_star_selected',
          message: 'PHD2 has no guide star selected.',
          statusCode: 409,
        );
      }
      rethrow;
    }

    // Return the star image data as JSON with base64-encoded pixels
    return jsonOk({
      "frame": starImage.frame,
      "width": starImage.width,
      "height": starImage.height,
      "starX": starImage.starX,
      "starY": starImage.starY,
      "pixels": base64Encode(starImage.pixels),
    });
  }

  static bool _isPhd2NoLockPosition(Object error) {
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

  static bool _isPhd2NoStarSelected(Object error) {
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
    final deviceId = requireString(payload, 'deviceId');
    final settle = _readSettle(payload);

    final backend = container.read(guidingBackendProvider);
    Future<void> start() => backend.guiderStartGuiding(
      deviceId: deviceId,
      settlePixels: settle.pixels,
      settleTime: settle.time,
      settleTimeout: settle.timeout,
    );
    if (isPhd2DeviceId(deviceId)) {
      await _runPhd2Start(start);
    } else {
      await start();
    }

    return jsonOk({"status": "guiding", "deviceId": deviceId});
  }

  Future<Response> handleGuiderStopGuiding(Request request) async {
    _logInfo('[API] POST /api/guider/stop-guiding');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final backend = container.read(guidingBackendProvider);
    Future<void> stop() => backend.guiderStopGuiding(deviceId: deviceId);
    if (isPhd2DeviceId(deviceId)) {
      await _runPhd2Stop(stop);
    } else {
      await stop();
    }

    return jsonOk({"status": "stopped", "deviceId": deviceId});
  }

  Future<Response> handleGuiderDither(Request request) async {
    _logInfo('[API] POST /api/guider/dither');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
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
      deviceId: deviceId,
      amount: amount,
      raOnly: optionalBool(payload, 'raOnly') ?? false,
      settlePixels: settle.pixels,
      settleTime: settle.time,
      settleTimeout: settle.timeout,
    );

    return jsonOk({"status": "dithering", "deviceId": deviceId});
  }

  Future<Response> handleGuiderLoop(Request request) async {
    _logInfo('[API] POST /api/guider/loop');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final backend = container.read(guidingBackendProvider);
    await backend.guiderLoop(deviceId: deviceId);

    return jsonOk({"status": "looping", "deviceId": deviceId});
  }

  Future<Response> handleGuiderFindStar(Request request) async {
    _logInfo('[API] POST /api/guider/find-star');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final backend = container.read(guidingBackendProvider);
    final double x;
    final double y;
    try {
      (x, y) = await backend.guiderFindStar(deviceId: deviceId);
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
          details: {'deviceId': deviceId},
          cause: error,
          stackTrace: stackTrace,
        );
      }
      rethrow;
    }

    return jsonOk({"x": x, "y": y, "deviceId": deviceId});
  }

  Future<Response> handleGuiderSetLockPosition(Request request) async {
    _logInfo('[API] POST /api/guider/set-lock-position');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final x = requireDouble(payload, 'x');
    final y = requireDouble(payload, 'y');

    final backend = container.read(guidingBackendProvider);
    await backend.guiderSetLockPosition(
      deviceId: deviceId,
      x: x,
      y: y,
      exact: optionalBool(payload, 'exact') ?? false,
    );

    return jsonOk({"status": "ok", "deviceId": deviceId, "x": x, "y": y});
  }

  Future<Response> handleGuiderGetLockPosition(Request request) async {
    final rawDeviceId = request.url.queryParameters['deviceId'];
    final deviceId = rawDeviceId?.trim();
    if (deviceId == null || deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }

    final backend = container.read(guidingBackendProvider);
    final (x, y) = await backend.guiderGetLockPosition(deviceId: deviceId);
    return jsonOk({"x": x, "y": y, "deviceId": deviceId});
  }

  Future<Response> handleGuiderDeselectStar(Request request) async {
    _logInfo('[API] POST /api/guider/deselect-star');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final backend = container.read(guidingBackendProvider);
    await backend.guiderDeselectStar(deviceId: deviceId);
    return jsonOk({"status": "ok", "deviceId": deviceId});
  }

  Future<Response> handleGuiderGetStarImage(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'];
    if (deviceId == null || deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }
    // Same contract as PHD2 star-image: absent → 50; supplied must be a
    // positive whole integer bounded by [_maxStarImageSize].
    final size =
        optionalQueryInt(
          request.url.queryParameters,
          'size',
          min: 1,
          max: _maxStarImageSize,
        ) ??
        50;

    final backend = container.read(guidingBackendProvider);
    final image = await backend.guiderGetStarImage(
      deviceId: deviceId,
      size: size,
    );

    return jsonOk({
      "frame": image.frame,
      "width": image.width,
      "height": image.height,
      "starX": image.starX,
      "starY": image.starY,
      "pixels": base64Encode(image.pixels),
      "deviceId": deviceId,
    });
  }

  Future<Response> handleBuiltinGuiderGetConfig(Request request) async {
    _logInfo('[API] GET /api/builtin-guider/config');
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

  Future<void> _runPhd2Start(Future<void> Function() start) async {
    if (_phd2StartDrain != null || _phd2StopInFlight) {
      throw HandlerFailure(
        code: 'guiding_command_busy',
        message: 'Another PHD2 start/stop command is already in progress.',
        statusCode: 409,
      );
    }
    final operation = Future<void>.sync(start);
    final drain = operation.then<void>((_) {}, onError: (_, __) {});
    _phd2StartDrain = drain;
    try {
      await operation;
    } finally {
      if (identical(_phd2StartDrain, drain)) _phd2StartDrain = null;
    }
  }

  Future<void> _runPhd2Stop(Future<void> Function() stop) async {
    if (_phd2StopInFlight) {
      throw HandlerFailure(
        code: 'guiding_command_busy',
        message: 'A PHD2 stop command is already in progress.',
        statusCode: 409,
      );
    }
    _phd2StopInFlight = true;
    try {
      final start = _phd2StartDrain;
      await stop();
      if (start != null) {
        await start;
        await stop();
      }
    } finally {
      _phd2StopInFlight = false;
    }
  }
}
